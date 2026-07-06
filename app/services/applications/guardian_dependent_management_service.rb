# frozen_string_literal: true

module Applications
  # Handles guardian/dependent user management for paper applications
  class GuardianDependentManagementService < BaseService
    SYNTHETIC_PHONE_RANDOM_SPACE = 10_000_000
    SYNTHETIC_PHONE_MAX_ATTEMPTS = 25

    attr_reader :params, :guardian_user, :dependent_user, :errors

    def initialize(params = nil, actor: nil, **keyword_params)
      super()
      @params = (params || keyword_params).with_indifferent_access
      @actor = actor
      @guardian_user = nil
      @dependent_user = nil
      @email_backed_portal_created_user_ids = []
      @errors = []
    end

    def process_guardian_scenario(guardian_id, new_guardian_attrs, applicant_data, relationship_type)
      result = nil

      ActiveRecord::Base.transaction do
        unless setup_guardian(guardian_id, new_guardian_attrs)
          result = failure('Failed to setup guardian')
          raise ActiveRecord::Rollback
        end

        applicant_data = applicant_data.deep_dup
        unless apply_contact_strategies(applicant_data)
          result = failure('Failed to apply contact strategies')
          raise ActiveRecord::Rollback
        end

        unless dependent_duplicate_detection_allows_creation?(applicant_data)
          result = failure('Failed to create dependent')
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

      create_relationship(relationship_type)
    end

    private

    def setup_guardian(guardian_id, new_guardian_attrs)
      if guardian_id.present?
        @guardian_user = User.find_by(id: guardian_id)
        return add_error?('Guardian not found') unless @guardian_user
      elsif attributes_present?(new_guardian_attrs)
        contact_flags = Applications::PaperContactFlags.new(params, scope: :guardian)
        guardian_attrs = contact_flags.apply_to(new_guardian_attrs)
        duplicate_detection = detect_duplicates(:paper_new_guardian, guardian_attrs)
        return false if duplicate_detection.blank?
        return block_duplicate(:paper_new_guardian) if duplicate_detection.hard_block

        result = UserCreationService.new(
          guardian_attrs,
          is_managing_adult: true,
          skip_user_lookup: true,
          skip_email_validation: contact_flags.skip_email_validation?,
          skip_phone_validation: contact_flags.skip_phone_validation?
        ).call
        return false unless result.success?

        @guardian_user = result.data[:user]
        track_email_backed_portal_created_user_id(result.data[:email_backed_portal_created_user_id])
        return false unless open_duplicate_review_case(@guardian_user, duplicate_detection)
      else
        return add_error?('Guardian information missing')
      end
      true
    end

    def create_dependent?(applicant_data)
      result = UserCreationService.new(applicant_data, is_managing_adult: false, skip_user_lookup: true).call
      return false unless result.success?

      @dependent_user = result.data[:user]
      track_email_backed_portal_created_user_id(result.data[:email_backed_portal_created_user_id])
      return false unless open_duplicate_review_case(@dependent_user, @dependent_duplicate_detection)

      true
    end

    def dependent_duplicate_detection_allows_creation?(applicant_data)
      @dependent_duplicate_detection = detect_duplicates(:paper_new_dependent, applicant_data)
      return false if @dependent_duplicate_detection.blank?
      return block_duplicate(:paper_new_dependent) if @dependent_duplicate_detection.hard_block

      true
    end

    def create_relationship(relationship_type)
      return add_error?('Relationship type required') if relationship_type.blank?

      GuardianRelationship.create!(
        guardian_user: @guardian_user,
        dependent_user: @dependent_user,
        relationship_type: relationship_type
      )
      true
    rescue ActiveRecord::RecordInvalid => e
      add_error?("Failed to create relationship: #{e.message}")
      false
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
        phone = unique_synthetic_phone
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

    def detect_duplicates(context, attrs)
      result = DuplicateDetectionService.new(
        context: context,
        attrs: duplicate_detection_attrs(attrs)
      ).call
      return result.data if result.success?

      add_error?("Duplicate detection failed: #{result.message}")
      nil
    end

    def block_duplicate(context)
      add_error?(duplicate_block_message(context))
    end

    def duplicate_block_message(context)
      case context
      when :paper_new_guardian
        'A guardian with this email or phone already exists. Select the existing guardian instead of creating a new one.'
      else
        'A dependent with this email or phone already exists. Select the existing dependent instead of creating a new one.'
      end
    end

    def open_duplicate_review_case(user, duplicate_detection)
      return true unless duplicate_detection&.recommended_action == :flag

      result = DuplicateReviewCases::CreateService.new(
        source: :paper_intake,
        subject_user: user,
        actor: @actor,
        reason_codes: duplicate_detection.reasons,
        candidates: duplicate_review_candidates_for(duplicate_detection),
        metadata: { intake_context: 'paper_intake' }
      ).call
      return true if result.success?

      add_error?(result.message)
      false
    end

    def duplicate_review_candidates_for(duplicate_detection)
      duplicate_detection.matched_users.map do |candidate|
        DuplicateReviewCases::CreateService::CandidateInput.new(
          candidate,
          duplicate_detection.reasons.first
        )
      end
    end

    def duplicate_detection_attrs(attrs)
      data = attrs.to_h.with_indifferent_access
      dob_holder = Users::Constituent.new
      dob_holder.date_of_birth = data[:date_of_birth] if data.key?(:date_of_birth)

      {
        email: User.normalize_email(data[:email]),
        phone: User.normalize_phone(data[:phone]),
        first_name: data[:first_name],
        last_name: data[:last_name],
        date_of_birth: dob_holder.date_of_birth,
        physical_address_1: data[:physical_address_1],
        physical_address_2: data[:physical_address_2],
        city: data[:city],
        state: data[:state],
        zip_code: data[:zip_code]
      }
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

    def failure(message)
      add_error?(message)
      Result.new(success: false, message: message, data: { errors: @errors })
    end
  end
end
