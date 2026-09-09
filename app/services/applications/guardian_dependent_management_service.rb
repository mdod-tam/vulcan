# frozen_string_literal: true

module Applications
  # Handles guardian/dependent user management for paper applications
  class GuardianDependentManagementService < BaseService
    SYNTHETIC_PHONE_RANDOM_SPACE = 10_000_000
    SYNTHETIC_PHONE_MAX_ATTEMPTS = 25
    DEPENDENT_CONTACT_COLLISION_MESSAGE = 'A dependent with this email or phone already exists. ' \
                                          'Select the existing dependent or correct the contact information.'

    # Raised only around the new-dependent User insert. The outer application writer catches it
    # after its transaction has rolled back, when PostgreSQL permits a fresh identity query.
    class DependentCreationConflict < StandardError; end

    attr_reader :params, :guardian_user, :dependent_user, :errors

    def initialize(params = nil, actor: nil, guardian_user: nil, dependent_user: nil,
                   preallocated_synthetic_phone: nil, **keyword_params)
      super()
      @params = (params || keyword_params).with_indifferent_access
      @actor = actor
      @guardian_user = guardian_user
      @dependent_user = dependent_user
      @preallocated_synthetic_phone = preallocated_synthetic_phone if
        User.synthetic_dependent_phone?(preallocated_synthetic_phone)
      @email_backed_portal_created_user_ids = []
      @errors = []
    end

    def process_guardian_scenario(guardian_id, applicant_data, relationship_type)
      result = nil

      ActiveRecord::Base.transaction do
        unless setup_guardian(guardian_id)
          result = failure('Failed to setup guardian')
          raise ActiveRecord::Rollback
        end

        applicant_data = applicant_data.deep_dup
        unless paper_dependent_contact_choices_valid?(applicant_data)
          result = failure('Dependent contact strategy refused the write')
          raise ActiveRecord::Rollback
        end

        unless dependent_identity_review_allows_creation?(applicant_data, relationship_type)
          result = failure('Dependent identity review refused the write')
          raise ActiveRecord::Rollback
        end

        unless apply_contact_strategies(applicant_data)
          result = failure('Failed to apply contact strategies')
          raise ActiveRecord::Rollback
        end

        unless create_dependent?(applicant_data)
          result = failure('Failed to create dependent')
          raise ActiveRecord::Rollback
        end

        unless create_relationship(relationship_type)
          result = failure('Failed to create relationship')
          raise ActiveRecord::Rollback
        end

        result = success(
          guardian: @guardian_user,
          dependent: @dependent_user,
          email_backed_portal_created_user_ids: @email_backed_portal_created_user_ids
        )
      end

      result
    end

    def apply_contact_strategies(applicant_data)
      return true unless @guardian_user

      # Strategies snapshot request-time contact choices into User fields.
      return false unless apply_email_strategy(applicant_data)
      return false unless apply_phone_strategy(applicant_data)

      apply_address_strategy(applicant_data)
      true
    end

    def apply_contact_strategies_for(guardian_user, applicant_data)
      @guardian_user = guardian_user
      data = applicant_data.to_h.with_indifferent_access
      return unless apply_contact_strategies(data)

      data
    end

    # Public method for creating guardian/dependent relationships
    # Used by controllers when users and relationships need to be created separately
    def create_guardian_relationship(relationship_type)
      return false unless @guardian_user && @dependent_user

      ActiveRecord::Base.transaction do
        locked_users = User.lock_for_merge_integrity!(@guardian_user, @dependent_user)
        @guardian_user = locked_users.fetch(@guardian_user.id)
        @dependent_user = locked_users.fetch(@dependent_user.id)

        eligibility_error = relationship_participant_error
        return add_error?("Failed to create relationship: #{eligibility_error}") if eligibility_error

        create_relationship_record!(relationship_type)
      end
      true
    rescue ActiveRecord::RecordNotFound
      add_error?('Failed to create relationship: a selected record is no longer available')
    rescue ActiveRecord::RecordInvalid => e
      add_error?("Failed to create relationship: #{e.record.errors.full_messages.to_sentence.presence || e.message}")
    rescue ActiveRecord::RecordNotUnique
      add_error?('Failed to create relationship: relationship already exists')
    end

    private

    def setup_guardian(guardian_id)
      return add_error?('Guardian information missing') if guardian_id.blank?

      @guardian_user = User.lock.find_by(id: guardian_id)
      return add_error?('Guardian not found') unless @guardian_user
      return add_error?('Selected guardian is not an eligible active constituent') unless @guardian_user.paper_guardian_candidate?

      true
    end

    def create_dependent?(applicant_data)
      result = UserCreationService.new(applicant_data, is_managing_adult: false, skip_user_lookup: true).call
      return false unless result.success?

      @dependent_user = result.data[:user]
      track_email_backed_portal_created_user_id(result.data[:email_backed_portal_created_user_id])
      record_no_match_confirmation(@dependent_user)

      true
    rescue ActiveRecord::RecordNotUnique
      raise DependentCreationConflict, 'Dependent creation collided with an existing unique record'
    end

    def dependent_identity_review_allows_creation?(applicant_data, relationship_type)
      review_owner = Applications::PaperIdentityReview.new(
        constituent_params: applicant_data,
        contact_flag_params: params,
        admin: @actor,
        submitted_token: params[:identity_decision],
        context: :dependent,
        context_data: { guardian: @guardian_user, relationship_type: relationship_type }
      )
      Applications::PaperIdentityCreationLock.lock!(review_owner.identity_facts)
      @identity_review = review_owner.call

      return add_error?('Duplicate detection failed. Try again.') if @identity_review.error?
      return add_error?(dependent_decision_error(@identity_review)) if @identity_review.invalid_decision?
      return add_error?(DEPENDENT_CONTACT_COLLISION_MESSAGE) if @identity_review.blocked?

      if @identity_review.confirmed?
        @confirmed_no_match = {
          candidate_ids: @identity_review.candidate_ids,
          reason_codes: @identity_review.reasons
        }
        return true
      end
      return true if @identity_review.clear?

      add_error?(dependent_decision_error(@identity_review))
    end

    # The replay pair is written here rather than by a follow-up update from the caller, so the key,
    # its fingerprint, and the relationship they identify commit together. Persisted separately,
    # either could outlive a rolled-back creation or be missing from a committed one, and a later
    # replay would resolve to the wrong answer. The two are meaningless apart -- a check constraint
    # keeps them present or absent together -- and both are absent for every non-portal writer.
    def create_relationship(relationship_type)
      return add_error?('Relationship type required') if relationship_type.blank?

      create_relationship_record!(relationship_type)
      true
    rescue ActiveRecord::RecordInvalid => e
      add_error?("Failed to create relationship: #{e.message}")
      false
    end

    def create_relationship_record!(relationship_type)
      GuardianRelationship.create!(
        guardian_user: @guardian_user,
        dependent_user: @dependent_user,
        relationship_type: relationship_type,
        portal_creation_key: params[:portal_creation_key].presence,
        portal_creation_fingerprint: params[:portal_creation_fingerprint].presence
      )
    end

    def relationship_participant_error
      return 'guardian must be an active constituent' unless relationship_participant_eligible?(@guardian_user)
      return 'dependent must be an active constituent' unless relationship_participant_eligible?(@dependent_user)

      nil
    end

    def relationship_participant_eligible?(user)
      user.is_a?(Users::Constituent) && user.public_login_active?
    end

    def apply_email_strategy(data)
      return true if params[:email_strategy].nil?

      case params[:email_strategy]
      when 'guardian'
        if @guardian_user&.email.present?
          data[:dependent_email] = @guardian_user.email
          data[:email] = "dependent-#{SecureRandom.uuid}@system.matvulcan.local"
        else
          # Fallback: generate a unique email if guardian email is missing
          data[:email] = "dependent-#{SecureRandom.uuid}@system.matvulcan.local"
          data[:dependent_email] = data[:email]
        end
        data[:communication_preference] = @guardian_user&.communication_preference
      when 'dependent'
        # Paper passes :dependent_email; portal passes :email. Mirror the submitted contact.
        data[:email] = data[:dependent_email] if data[:email].blank? && data[:dependent_email].present?
        return apply_email_strategy_with('guardian', data) if data[:email].blank?

        data[:dependent_email] = data[:email]

      else
        return apply_email_strategy_with('guardian', data)
      end

      # Final safety check: ensure email is always set
      return true if data[:email].present?

      data[:email] = "dependent-#{SecureRandom.uuid}@system.matvulcan.local"
      true
    end

    def apply_phone_strategy(data)
      return true if params[:phone_strategy].nil?

      case params[:phone_strategy]
      when 'guardian'
        data[:dependent_phone] = @guardian_user.phone
        phone = @preallocated_synthetic_phone.presence || unique_synthetic_phone
        return false if phone.blank?

        data[:phone] = phone
      when 'dependent'
        # Paper passes :dependent_phone; portal passes :phone. Mirror the submitted contact.
        data[:phone] = data[:dependent_phone] if data[:phone].blank? && data[:dependent_phone].present?
        return apply_phone_strategy_with('guardian', data) if data[:phone].blank?

        data[:dependent_phone] = data[:phone]

      else
        return apply_phone_strategy_with('guardian', data)
      end
      true
    end

    def apply_address_strategy(data)
      return if params[:address_strategy] == 'dependent'

      data[:physical_address_1] = @guardian_user.physical_address_1
      data[:physical_address_2] = @guardian_user.physical_address_2
      data[:city] = @guardian_user.city
      data[:state] = @guardian_user.state
      data[:zip_code] = @guardian_user.zip_code
    end

    def apply_email_strategy_with(strategy, data)
      @params[:email_strategy] = strategy
      apply_email_strategy(data)
    end

    def apply_phone_strategy_with(strategy, data)
      @params[:phone_strategy] = strategy
      apply_phone_strategy(data)
    end

    def unique_synthetic_phone
      SYNTHETIC_PHONE_MAX_ATTEMPTS.times do
        candidate = synthetic_phone_candidate
        return candidate unless User.exists_with_phone?(candidate)
      end

      add_error?('Unable to generate unique synthetic dependent phone')
      nil
    end

    def synthetic_phone_candidate
      value = SecureRandom.random_number(SYNTHETIC_PHONE_RANDOM_SPACE)
      digits = format('%07d', value)
      "000-#{digits[0, 3]}-#{digits[3, 4]}"
    end

    def attributes_present?(attrs)
      attrs.present? && attrs.values.any?(&:present?)
    end

    def paper_dependent_contact_choices_valid?(applicant_data)
      choice = Applications::PaperDependentContactChoice.new(
        applicant_data: applicant_data,
        strategy_params: params
      ).call
      return add_error?(choice.message) unless choice.valid?

      true
    end

    def dependent_decision_error(review)
      return 'This identity review expired. Review the possible matches again.' if review.decision_reason == :expired
      return 'The dependent, guardian, relationship, or possible matches changed. Review them again.' if review.decision_reason == :mismatched

      "#{review.candidates.size} possible #{'match'.pluralize(review.candidates.size)} found. " \
        'Select an eligible existing dependent or confirm these are different people.'
    end

    def record_no_match_confirmation(user)
      return if @confirmed_no_match.blank?

      AuditEventService.log(
        action: 'paper_identity_no_match_confirmed',
        actor: @actor,
        auditable: user,
        metadata: {
          decision_context: 'paper_new_dependent',
          role: 'dependent',
          guardian_id: @guardian_user.id,
          relationship_type: params[:relationship_type],
          candidate_ids: @confirmed_no_match[:candidate_ids],
          candidate_count: @confirmed_no_match[:candidate_ids].size,
          reason_codes: @confirmed_no_match[:reason_codes]
        }
      )
    end

    def track_email_backed_portal_created_user_id(user_id)
      @email_backed_portal_created_user_ids << user_id.to_s if user_id.present?
    end

    def add_error?(message)
      @errors << message
      false
    end

    def success(data)
      Result.new(success: true, data: data)
    end

    def failure(message, data = nil)
      add_error?(message)
      Result.new(success: false, message: message, data: data || { errors: @errors })
    end
  end
end
