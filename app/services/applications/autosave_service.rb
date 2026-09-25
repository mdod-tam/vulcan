# frozen_string_literal: true

module Applications
  class AutosaveService < BaseService
    class IneligibleAutosaveTargetError < StandardError; end

    attr_reader :current_user, :params

    def initialize(current_user:, params:)
      super()
      @current_user = current_user
      @params = params
    end

    def call
      return autosave_error_result('Field name is required') if field_name.blank?
      return autosave_error_result('File uploads are not supported for autosave') if file_field?

      initialize_application
      return autosave_error_result('Unable to find or create application') if @application.nil?

      save_field
    end

    private

    def field_name
      @field_name ||= params[:field_name]
    end

    def field_value
      @field_value ||= params[:field_value]
    end

    def file_field?
      field_name.ends_with?('proof]') || field_name.include?('file')
    end

    def initialize_application
      @application = if params[:id].present?
                       find_existing_application
                     else
                       build_draft_application
                     end
    end

    def find_existing_application
      # Search in both user's own applications and applications they manage as guardian.
      # No fallback to a new or resumed draft: the caller supplied an exact application id, so if
      # it can't be found (or isn't owned/managed by current_user), autosave must fail closed rather
      # than silently substituting a different draft.
      current_user.applications.find_by(id: params[:id]) ||
        current_user.managed_applications.find_by(id: params[:id])
    end

    # Without an id this is only the applicant a draft is for. Whether that means resuming an
    # existing draft, creating one, or refusing is decided under lock in
    # lock_and_requalify_participant!, so concurrent first saves resolve to a single draft.
    def build_draft_application
      dependent_id = authorized_dependent_id
      return nil if dependent_id == :unauthorized

      create_new_application(dependent_id)
    end

    def create_new_application(dependent_id = nil)
      current_user.applications.new.tap do |app|
        apply_default_attributes(app)

        # Set up dependent relationship if this is for a dependent
        if dependent_id.present?
          app.user_id = dependent_id
          app.managing_guardian_id = current_user.id
        end
      end
    end

    def dependent_id_param
      params[:user_id].presence || params.dig(:application, :user_id).presence
    end

    def authorized_dependent_id
      dependent_id = dependent_id_param
      return nil if dependent_id.blank?

      current_user.dependents.exists?(id: dependent_id) ? dependent_id : :unauthorized
    end

    def apply_default_attributes(app)
      app.status = :draft
      app.application_date = Time.current
      app.submission_method = :online
      app.application_type ||= :new
    end

    def save_field
      attribute_name = extract_attribute_name
      target_model = autosave_target_for(attribute_name)
      return field_error_result('This field cannot be autosaved') if target_model == :ignored

      result = nil
      ActiveRecord::Base.transaction do
        lock_and_requalify_participant!
        @revisions = AutosaveRevisions.new(@application)
        @outcome = @revisions.prepare!(context: params[:autosave_context],
                                       revision: params[:autosave_revision],
                                       field: attribute_name)
        result = if @outcome == :superseded
                   { success: true }
                 else
                   target_model == :user ? save_user_field(attribute_name) : save_application_field(attribute_name)
                 end
      end

      result[:success] ? autosave_success_result : result
    rescue AutosaveRevisions::InvalidRevision
      autosave_error_result(I18n.t('applications.autosave.refresh', locale: @target_user&.effective_message_locale || I18n.default_locale))
    rescue IneligibleAutosaveTargetError => e
      { success: false, errors: { base: [e.message] } }
    rescue StandardError => e
      # The exception text can carry database or internal detail, so it stays in the log.
      Rails.logger.error("Error autosaving field #{attribute_name}: #{e.message}")
      autosave_error_result('This field could not be saved')
    end

    # Locks the target participant (and, for a dependent application, the guardian) through
    # the shared merge-integrity primitive before any write, so a concurrent merge and a
    # concurrent autosave can never interleave. For an application that already exists in the
    # database, also locks and reloads it and rechecks it is still exactly the draft that was
    # found -- never substituting a different one -- still belongs to the same participant
    # (ownership itself could have been transferred by a merge in the window between the
    # initial unlocked lookup and this lock being granted), and that any guardian relationship
    # is still authorized. Without an id, resumes the actor's draft for this applicant from the
    # now-locked inventory when one exists; otherwise checks the shared
    # Application.sibling_application_eligibility_error policy against that inventory before a new
    # draft is created.
    def lock_and_requalify_participant!
      initial_target_id = @application.user_id
      guardian_ids = GuardianRelationship.where(dependent_id: initial_target_id).pluck(:guardian_id)
      locked_users = User.lock_for_merge_integrity!(
        current_user.id,
        initial_target_id,
        @application.managing_guardian_id,
        guardian_ids
      )
      @locked_users = locked_users
      @current_user = locked_users.fetch(current_user.id)
      @target_user = locked_users.fetch(initial_target_id)

      validate_constituent_participant!(@current_user)
      validate_constituent_participant!(@target_user)

      @locked_guardian_relationships = GuardianRelationship
                                       .where(dependent_id: initial_target_id)
                                       .order(:id)
                                       .lock
                                       .to_a
      missing_guardian_ids = @locked_guardian_relationships.map(&:guardian_id).uniq - locked_users.keys
      raise IneligibleAutosaveTargetError, 'This guardian relationship changed while the application was being saved.' if missing_guardian_ids.any?

      if @application.persisted?
        exact_application = Application.where(id: @application.id).order(:id).lock.first
        raise IneligibleAutosaveTargetError, 'This application no longer belongs to this participant.' unless
          exact_application&.user_id == initial_target_id

        @application = exact_application
      else
        locked_inventory = Application.where(user_id: initial_target_id).order(:id).lock.to_a
        resumable_draft = Application.resumable_portal_draft(locked_inventory, actor_id: current_user.id)
        if resumable_draft
          @application = resumable_draft
        else
          error = Application.sibling_application_eligibility_error(locked_inventory, target_application: @application)
          raise IneligibleAutosaveTargetError, error if error
        end
      end

      install_locked_application_associations!
      requalify_application_authority!
      raise IneligibleAutosaveTargetError, 'This application is no longer a draft.' unless @application.status == 'draft'
    end

    def validate_constituent_participant!(user)
      raise IneligibleAutosaveTargetError, 'This record is no longer an eligible active record.' unless user.public_login_active?

      return if user.constituent?

      raise IneligibleAutosaveTargetError, 'Only constituent records can use the constituent application portal.'
    end

    def install_locked_application_associations!
      @application.association(:user).target = @target_user
      @locked_guardian_relationships.each do |relationship|
        relationship.association(:guardian_user).target = @locked_users.fetch(relationship.guardian_id)
        relationship.association(:dependent_user).target = @target_user
      end
    end

    def requalify_application_authority!
      dependent_application = @target_user.id != current_user.id || @application.managing_guardian_id.present?

      if dependent_application
        unless @target_user.id != current_user.id && @application.managing_guardian_id == current_user.id
          raise IneligibleAutosaveTargetError, 'This application is no longer managed by this guardian.'
        end
        raise IneligibleAutosaveTargetError, 'This guardian relationship is no longer authorized.' unless locked_guardian_relationship

        @application.association(:managing_guardian).target = current_user
      elsif @application.user_id != current_user.id
        raise IneligibleAutosaveTargetError, 'This application no longer belongs to this participant.'
      end
    end

    def locked_guardian_relationship
      @locked_guardian_relationships.find do |relationship|
        relationship.guardian_id == current_user.id && relationship.dependent_id == @target_user.id
      end
    end

    def extract_attribute_name
      # Handle nested medical provider attributes
      if field_name.include?('medical_provider_attributes') &&
         field_name =~ /medical_provider_attributes\]\[([^\]]+)\]/
        return "medical_provider_#{::Regexp.last_match(1)}"
      end

      # Handle standard application fields
      return field_name[12..-2] if field_name.start_with?('application[') && field_name.end_with?(']')

      field_name
    end

    def autosave_target_for(attribute_name)
      user_fields = %w[hearing_disability vision_disability speech_disability
                       mobility_disability cognition_disability]
      application_fields = %w[annual_income household_size maryland_resident
                              self_certify_disability terms_accepted information_verified
                              medical_release_authorized medical_provider_name
                              medical_provider_phone medical_provider_fax medical_provider_email
                              alternate_contact_name alternate_contact_phone alternate_contact_email
                              alternate_contact_relationship_type]

      return :user if user_fields.include?(attribute_name)
      return :application if application_fields.include?(attribute_name)

      :ignored
    end

    # Called only from within save_field's transaction, after lock_and_requalify_participant!
    # has already locked and revalidated the target user and (if persisted) the application.
    def save_user_field(attribute)
      value = cast_user_field_value(attribute, field_value)
      was_new_record = @application.new_record?

      # Autosave persists individual draft fields without running full-form validations.
      # rubocop:disable Rails/SkipsModelValidations
      @target_user.update_column(attribute, value)
      @application.last_visited_step = attribute
      @application.save!(validate: false)
      # rubocop:enable Rails/SkipsModelValidations
      log_application_created_event if was_new_record
      { success: true }
    end

    # Called only from within save_field's transaction, after lock_and_requalify_participant!
    # has already locked and revalidated the target participant and (if persisted) the
    # application itself.
    def save_application_field(attribute)
      validation_result = validate_field_value(attribute)
      return validation_result unless validation_result[:success]

      processed_value = cast_application_field_value(attribute, field_value)

      begin
        @application.assign_attributes(attribute => processed_value)
      rescue ActiveRecord::UnknownAttributeError
        return autosave_error_result('This field cannot be autosaved')
      end

      @application.valid?
      return { success: false, errors: { field_name => @application.errors[attribute] } } if @application.errors[attribute].any?

      was_new_record = @application.new_record?

      @application.save!(validate: false)
      log_application_created_event if was_new_record
      # Autosave records draft progress field-by-field without full validation.
      # rubocop:disable Rails/SkipsModelValidations
      @application.update_column(:last_visited_step, attribute)
      # rubocop:enable Rails/SkipsModelValidations
      { success: true }
    end

    def cast_user_field_value(attribute, value)
      if %w[hearing_disability vision_disability speech_disability
            mobility_disability cognition_disability].include?(attribute)
        ActiveModel::Type::Boolean.new.cast(value)
      else
        value
      end
    end

    def cast_application_field_value(attribute, value)
      if %w[maryland_resident self_certify_disability].include?(attribute)
        ActiveModel::Type::Boolean.new.cast(value)
      else
        value
      end
    end

    # A cleared field is saved as cleared, as a full draft save would store it; otherwise the draft
    # would keep the old number and bring it back on the next load.
    def validate_field_value(attribute)
      return { success: true } if field_value.blank?

      case attribute
      when 'annual_income'
        return field_error_result('Must be a valid number') unless field_value.to_s.match?(/\A\d+(\.\d+)?\z/)
      when 'household_size'
        return field_error_result('Must be a valid integer') unless field_value.to_s.match?(/\A\d+\z/)
      end

      { success: true }
    end

    def autosave_success_result
      { success: true, application_id: @application.id, outcome: @outcome.to_s,
        revision: params[:autosave_revision].to_i, current_revision: @revisions.acknowledged_revision,
        value: (autosave_target_for(extract_attribute_name) == :user ? @target_user : @application).public_send(extract_attribute_name) }
    end

    def autosave_error_result(message)
      { success: false, errors: { base: [message] } }
    end

    def field_error_result(message)
      { success: false, errors: { field_name => [message] } }
    end

    def log_application_created_event
      AuditEventService.log(
        action: 'application_created',
        actor: current_user,
        auditable: @application,
        metadata: {
          submission_method: @application.submission_method,
          initial_status: @application.status
        }
      )
    end
  end
end
