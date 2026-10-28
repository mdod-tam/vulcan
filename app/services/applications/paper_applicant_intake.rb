# frozen_string_literal: true

module Applications
  # Selects or creates the applicant inside the paper application transaction.
  class PaperApplicantIntake
    ADULT_CONTACT_FIELDS = %i[
      email phone phone_type physical_address_1 physical_address_2
      city state zip_code communication_preference locale
      preferred_means_of_communication referral_source
    ].freeze
    APPLICANT_DISABILITY_FIELDS = %i[
      hearing_disability vision_disability speech_disability
      mobility_disability cognition_disability
    ].freeze

    attr_reader :constituent, :guardian_user_for_app, :identity_review, :created_portal_user_ids

    def initialize(params:, admin:, errors:)
      @params = params
      @admin = admin
      @errors = errors
      @created_portal_user_ids = []
    end

    def call
      guardian_id = params[:guardian_id]
      applicant_data = params[:constituent]
      relationship_type = params[:relationship_type]
      dependent_id = params[:dependent_id]
      existing_constituent_id = params[:existing_constituent_id]

      if params[:identity_candidate_id].present?
        process_reviewed_selection
      elsif existing_self_applicant_scenario?(existing_constituent_id)
        process_existing_self_applicant(existing_constituent_id)
      elsif existing_dependent_scenario?(guardian_id, dependent_id)
        process_existing_dependent(guardian_id, dependent_id, relationship_type)
      elsif guardian_scenario?(guardian_id, applicant_data)
        process_guardian_dependent(guardian_id, applicant_data, relationship_type)
      elsif self_applicant_scenario?(applicant_data)
        process_self_applicant(applicant_data)
      elsif dependent_with_unsaved_guardian?(applicant_data)
        add_error('Save or select the guardian before submitting the paper application.')
      else
        add_error('Sufficient constituent or guardian/dependent parameters missing.')
        false
      end
    end

    def record_identity_decision!(application)
      return unless @identity_review

      DuplicateReviewCases::CreateService.record_paper_decision!(
        review: @identity_review, user: @constituent, actor: @admin,
        rationale: params[:identity_rationale], receipt: params[:identity_review_receipt], application: application
      )
    end

    def recover_dependent_creation_conflict
      Rails.logger.warn('Dependent creation hit a unique constraint; identity review recomputed after rollback')
      guardian = User.find_by(id: params[:guardian_id])
      review = if guardian&.paper_guardian_candidate?
                 Applications::PaperIdentityReview.new(
                   constituent_params: params[:constituent],
                   contact_flag_params: params,
                   admin: @admin,
                   submitted_token: nil,
                   context: :dependent,
                   context_data: { guardian: guardian, relationship_type: params[:relationship_type] }
                 ).call
               end

      if review&.blocked?
        add_error(GuardianDependentManagementService::DEPENDENT_CONTACT_COLLISION_MESSAGE)
      else
        add_error('Dependent contact information changed while saving. ' \
                  'Review the dependent before trying again.')
      end
    rescue StandardError => e
      log_error(e, 'Could not classify a dependent creation conflict after rollback')
      add_error('Dependent contact information changed while saving. ' \
                'Review the dependent before trying again.')
    end

    private

    attr_reader :params

    def existing_self_applicant_scenario?(existing_constituent_id)
      existing_constituent_id.present? && params[:applicant_type] != 'dependent'
    end

    def process_existing_self_applicant(existing_constituent_id)
      user = User.lock.find_by(id: existing_constituent_id)
      return add_error('Applicant not found') unless user
      return add_error('Selected user is not eligible as an applicant.') unless user.paper_applicant_candidate?

      return false unless paper_application_eligible?(user, subject: :constituent)

      return add_error('Verify contact information against the paper application before submitting.') unless existing_adult_contact_info_verified?

      @constituent = user

      return false unless update_existing_applicant_disability_info(user)

      if params[:constituent].present? && attributes_present?(params[:constituent]) &&
         existing_adult_contact_updates_allowed? && !update_existing_adult_contact_info(user)
        return false
      end

      true
    end

    def existing_adult_contact_info_verified?
      ActiveModel::Type::Boolean.new.cast(params.fetch(:contact_info_verified, false))
    end

    def existing_adult_contact_updates_allowed?
      params[:contact_info_mode].to_s != 'on_file'
    end

    def guardian_scenario?(guardian_id, applicant_data)
      guardian_id.present? && attributes_present?(applicant_data) &&
        params[:applicant_type] == 'dependent'
    end

    def existing_dependent_scenario?(guardian_id, dependent_id)
      guardian_id.present? && dependent_id.present? && params[:applicant_type] == 'dependent'
    end

    def process_existing_dependent(guardian_id, dependent_id, _relationship_type)
      locked_users = User.lock.where(id: [guardian_id, dependent_id]).order(:id).index_by { |user| user.id.to_s }
      guardian = locked_users[guardian_id.to_s]
      dependent = locked_users[dependent_id.to_s]

      return add_error('Guardian not found') unless guardian
      return add_error('Dependent not found') unless dependent
      return add_error('Selected guardian is not an eligible active constituent.') unless guardian.paper_guardian_candidate?
      return add_error('Selected dependent is not an eligible constituent.') unless dependent.paper_dependent_candidate?

      return false unless ensure_guardian_relationship(guardian, dependent)
      return false unless update_dependent_and_validate_eligibility(dependent)

      @guardian_user_for_app = guardian
      @constituent = dependent
      true
    end

    def ensure_guardian_relationship(guardian, dependent)
      rel = GuardianRelationship.lock.find_by(guardian_id: guardian.id, dependent_id: dependent.id)
      return true if rel.present?

      add_error('The selected dependent is not on file for this guardian. Choose an on-file dependent or contact MAT support.')
    end

    def update_dependent_and_validate_eligibility(dependent)
      return false unless paper_application_eligible?(dependent, subject: :dependent)

      return false unless update_existing_applicant_disability_info(dependent)

      return false if params[:constituent].present? && attributes_present?(params[:constituent]) && !update_dependent_contact_info(dependent)

      true
    end

    def self_applicant_scenario?(applicant_data)
      attributes_present?(applicant_data) && params[:applicant_type] != 'dependent'
    end

    def dependent_with_unsaved_guardian?(applicant_data)
      params[:applicant_type] == 'dependent' &&
        (ActiveModel::Type::Boolean.new.cast(params[:unsaved_guardian_present]) ||
         attributes_present?(applicant_data) || attributes_present?(params[:guardian_attributes]))
    end

    def process_guardian_dependent(guardian_id, applicant_data, relationship_type)
      service = GuardianDependentManagementService.new(params, actor: @admin)
      result = service.process_guardian_scenario(guardian_id, applicant_data, relationship_type)
      @identity_review = service.identity_review

      if result.success?
        @guardian_user_for_app = result.data[:guardian]
        @constituent = result.data[:dependent]

        track_email_backed_portal_created_user_ids(result.data[:email_backed_portal_created_user_ids])

        paper_application_eligible?(@constituent, subject: :dependent)
      else
        @errors.concat(service.errors)
        false
      end
    end

    def process_self_applicant(applicant_data)
      contact_flags = paper_contact_flags(:constituent)
      @identity_review = review_paper_identity(applicant_data)
      return false unless identity_review_permits_creation?(@identity_review)

      applicant_data = contact_flags.apply_to(applicant_data)

      result = UserCreationService.new(
        applicant_data,
        is_managing_adult: true,
        skip_user_lookup: true,
        skip_email_validation: contact_flags.skip_email_validation?,
        skip_phone_validation: contact_flags.skip_phone_validation?
      ).call

      if result.success?
        @constituent = result.data[:user]
        track_email_backed_portal_created_user_id(result.data[:email_backed_portal_created_user_id])

        return false unless paper_application_eligible?(@constituent, subject: :constituent)

        true
      else
        @errors.concat(result.data[:errors] || [result.message])
        false
      end
    end

    def review_paper_identity(applicant_data)
      review = Applications::PaperIdentityReview.new(
        constituent_params: applicant_data,
        admin: @admin,
        contact_flag_params: params,
        submitted_token: params[:identity_review_receipt],
        determination: params[:identity_determination]
      )

      # Use the review facts for both the lock and the search.
      Applications::PaperIdentityCreationLock.lock!(review.identity_facts)
      review.call(lock: true)
    end

    def identity_review_permits_creation?(review)
      return add_error(PaperIdentityReview::INVALID_DATE_OF_BIRTH_MESSAGE) if review.invalid_input?
      return add_error('Duplicate detection failed. Try again.') if review.error?
      return add_error('The applicant details or possible matches changed since you reviewed them. Review again.') if review.invalid_decision?

      if review.blocked?
        return add_error('An applicant with this email or phone already exists. ' \
                         'Select the existing applicant instead of creating a new one.')
      end

      # An override requires a rationale. A clear review has no staff decision to record.
      if review.confirmed?
        return add_error('Explain the identity decision before continuing.') if params[:identity_rationale].blank?

        return true
      end

      return true if review.clear?

      add_error(no_match_decision_error(review.decision_reason, review.candidates.size))
      false
    end

    def no_match_decision_error(reason, candidate_count)
      return 'This review expired. Search again before creating a new constituent.' if reason == :expired

      if reason == :mismatched
        return 'The applicant details or the possible matches changed since you reviewed them. ' \
               'Search again before creating a new constituent.'
      end

      "#{candidate_count} possible #{'match'.pluralize(candidate_count)} found. " \
        'Review them and either select the existing constituent or confirm this is a different person.'
    end

    def process_reviewed_selection
      dependent = params[:applicant_type] == 'dependent'
      guardian = User.find_by(id: params[:guardian_id]) if dependent
      owner = PaperIdentityReview.new(
        constituent_params: params[:constituent], admin: @admin, contact_flag_params: params,
        submitted_token: params[:identity_review_receipt], selected_candidate_id: params[:identity_candidate_id],
        context: dependent ? :dependent : :self_applicant,
        context_data: { guardian: guardian, relationship_type: params[:relationship_type] }
      )
      PaperIdentityCreationLock.lock!(owner.identity_facts)
      @identity_review = owner.call(lock: true)
      return add_error(PaperIdentityReview::INVALID_DATE_OF_BIRTH_MESSAGE) if @identity_review.invalid_input?
      return add_error('Review the current matches and select an eligible person.') unless @identity_review.selected?
      return add_error('Explain the identity decision before continuing.') if params[:identity_rationale].blank?

      if dependent
        process_existing_dependent(guardian&.id, @identity_review.selected_user.id, params[:relationship_type])
      else
        process_existing_self_applicant(@identity_review.selected_user.id)
      end
    end

    def paper_contact_flags(scope)
      Applications::PaperContactFlags.new(params, scope: scope)
    end

    def track_email_backed_portal_created_user_ids(user_ids)
      Array(user_ids).each { |user_id| track_email_backed_portal_created_user_id(user_id) }
    end

    def track_email_backed_portal_created_user_id(user_id)
      @created_portal_user_ids << user_id.to_s if user_id.present?
    end

    def paper_application_eligible?(user, subject:)
      result = PaperApplicationEligibility.call(user)
      return true if result.eligible?

      add_error(result.refusal_message(subject: subject))
    end

    def update_dependent_contact_info(dependent)
      attrs = params[:constituent]
      return true if attrs.blank?

      attrs = apply_dependent_contact_strategies!(attrs, dependent: dependent)
      return false if attrs.nil?

      updates = build_dependent_contact_updates(attrs)
      return true if updates.empty?

      if dependent.update(updates)
        Rails.logger.info "Updated contact info for dependent #{dependent.id}: #{updates.keys.join(', ')}"
        true
      else
        add_error("Failed to update dependent information: #{dependent.errors.full_messages.join(', ')}")
        false
      end
    rescue ActiveRecord::RecordInvalid => e
      add_error("Failed to update dependent information: #{e.record.errors.full_messages.join(', ')}")
      false
    end

    def update_existing_applicant_disability_info(user)
      attrs = params[:constituent]
      return true if attrs.blank?

      updates = build_disability_updates(attrs)
      return true if updates.empty?

      if user.update(updates)
        true
      else
        add_error("Failed to update applicant disability information: #{user.errors.full_messages.join(', ')}")
        false
      end
    end

    def build_disability_updates(attrs)
      APPLICANT_DISABILITY_FIELDS.each_with_object({}) do |field, updates|
        updates[field] = attrs[field] if attrs.key?(field)
      end
    end

    def build_dependent_contact_updates(attrs)
      data = attrs.with_indifferent_access
      updates = {}

      %i[email phone dependent_email dependent_phone].each do |field|
        updates[field] = data[field] if data.key?(field)
      end

      %i[
        physical_address_1 physical_address_2 city state zip_code
        locale communication_preference preferred_means_of_communication
        phone_type referral_source
      ].each do |field|
        updates[field] = data[field] if data[field].present?
      end

      updates
    end

    def apply_dependent_contact_strategies!(attrs, dependent: nil)
      guardian = guardian_for_dependent_contact_update
      return attrs.deep_dup if guardian.blank?

      choice = Applications::PaperDependentContactChoice.new(
        applicant_data: attrs,
        strategy_params: params,
        existing_dependent: dependent,
        guardian: guardian
      ).call
      unless choice.valid?
        add_error(choice.message)
        return nil
      end

      strategy_service = GuardianDependentManagementService.new(params)
      applied = strategy_service.apply_contact_strategies_for(guardian, choice.resolved_applicant_data)
      if applied
        applied
      else
        @errors.concat(strategy_service.errors)
        nil
      end
    end

    def guardian_for_dependent_contact_update
      @guardian_user_for_app || User.find_by(id: params[:guardian_id])
    end

    def update_existing_adult_contact_info(user)
      persist_adult_contact_updates!(user, params[:constituent])
    end

    def persist_adult_contact_updates!(user, constituent_attrs)
      return true if constituent_attrs.blank?

      flagged = paper_contact_flags(:constituent).apply_to(constituent_attrs)
      updates = build_adult_contact_updates(flagged)
      return true if updates.empty?

      changed_fields = contact_field_changes(user, updates)
      return true if changed_fields.empty?

      if user.update(updates)
        log_constituent_contact_updated!(user, changed_fields)
        true
      else
        add_error("Failed to update applicant information: #{user.errors.full_messages.join(', ')}")
        false
      end
    end

    def contact_field_changes(user, updates)
      updates.each_with_object({}) do |(key, new_val), changes|
        old_val = user.read_attribute(key)
        changes[key] = { from: old_val, to: new_val } if old_val.to_s != new_val.to_s
      end
    end

    def log_constituent_contact_updated!(user, changed_fields)
      AuditEventService.log(
        action: 'constituent_contact_updated',
        actor: @admin,
        auditable: user,
        metadata: {
          source: 'paper_application',
          changes: changed_fields
        }
      )
    end

    def build_adult_contact_updates(attrs)
      updates = build_contact_updates(attrs, fields: ADULT_CONTACT_FIELDS)
      paper_contact_flags(:constituent).apply_clear_flags_to(updates)
    end

    def build_contact_updates(attrs, fields:, aliases: {})
      updates = {}
      fields.each { |f| updates[f] = attrs[f] if attrs[f].present? }
      aliases.each { |src, dest| updates[dest] = attrs[src] if attrs[src].present? }
      updates
    end

    def attributes_present?(attrs)
      attrs.present? && attrs.values.any?(&:present?)
    end

    def add_error(message)
      @errors << message
      false
    end

    def log_error(exception, message)
      Rails.logger.error "#{message}: #{exception.class.name}"
    end
  end
end
