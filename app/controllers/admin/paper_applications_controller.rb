# frozen_string_literal: true

module Admin
  class PaperApplicationsController < Admin::BaseController
    include ParamCasting
    include TurboStreamResponseHandling

    before_action :cast_complex_boolean_params, only: %i[create update]

    USER_BASE_FIELDS = %i[
      first_name middle_initial last_name email phone phone_type
      physical_address_1 physical_address_2 city state zip_code
      communication_preference locale date_of_birth
      preferred_means_of_communication referral_source
    ].freeze

    USER_DISABILITY_FIELDS = %i[
      self_certify_disability hearing_disability vision_disability speech_disability
      mobility_disability cognition_disability
    ].freeze

    DEPENDENT_BASE_FIELDS = %i[
      first_name last_name date_of_birth
      physical_address_1 physical_address_2 city state zip_code
      dependent_email dependent_phone phone_type locale
      preferred_means_of_communication referral_source
    ].freeze

    APPLICATION_FIELDS = %i[
      household_size annual_income maryland_resident self_certify_disability
      medical_provider_name medical_provider_phone medical_provider_fax
      medical_provider_email terms_accepted information_verified
      medical_release_authorized
      alternate_contact_name alternate_contact_phone alternate_contact_email
    ].freeze

    def new
      @paper_application = {
        application: Application.new,
        guardian_attributes: Users::Constituent.new, # For fields_for
        applicant_attributes: {}, # For disability attributes
        constituent: Constituent.new, # For dependent or self-applicant
        show_create_new_adult: false
      }
      # Ensure guardian_attributes is an empty hash if not already set,
      # or build from an existing model if @paper_application was a real model instance.
      # For simplicity with the current hash structure:

      @show_create_guardian_form = params[:show_create_guardian_form].present?
    end

    def create
      log_file_and_form_params
      service_params = paper_application_processing_params # Use the new method
      Rails.logger.debug { "Service params before service call: #{service_params.inspect}" }

      service = Applications::PaperApplicationService.new(
        params: service_params,
        admin: current_user
      )

      service_result = service.create

      if service_result
        success_message = generate_success_message(service.application)
        success_message += " #{service.reconciliation_note}" if service.reconciliation_note.present?
        handle_success_response(
          html_redirect_path: admin_application_path(service.application),
          html_message: success_message,
          turbo_message: success_message,
          turbo_redirect_path: admin_application_path(service.application)
        )
      else
        Rails.logger.info "[PaperApplicationsController] Handling service failure, request format: #{request.format}"

        # If the application was persisted but reconciliation failed, redirect to the application
        # with an alert instead of re-rendering the form.
        if service.application&.persisted?
          error_msg = service.errors.any? ? service.errors.join('; ') : 'An unexpected error occurred.'
          handle_error_response(
            html_redirect_path: admin_application_path(service.application),
            error_message: error_msg
          )
        else
          handle_service_failure(service)
        end
      end
    end

    def update
      log_file_and_form_params
      service_params = paper_application_processing_params # Use the new method
      Rails.logger.debug { "Service params for update: #{service_params.inspect}" }

      application = Application.find(params[:id])
      # ... (logging from original update can be kept or removed as needed)

      service = Applications::PaperApplicationService.new(
        params: service_params,
        admin: current_user
      )

      if service.update(application)
        update_message = generate_success_message(application)
        handle_success_response(
          html_redirect_path: admin_application_path(application),
          html_message: update_message,
          turbo_message: update_message,
          turbo_redirect_path: admin_application_path(application)
        )
      elsif service.application&.persisted? && service.errors.any? { |e| e.include?('Workflow status update failed') }
        # If the application was updated but reconciliation failed, redirect to the application
        # with an alert instead of re-rendering the form.
        error_msg = service.errors.join('; ')
        handle_error_response(
          html_redirect_path: admin_application_path(service.application),
          error_message: error_msg
        )
      else
        handle_service_failure(service, application)
      end
    end

    # Load dependent form for editing or creating new dependent
    # Used by Turbo Frame to dynamically load pre-filled form when existing dependent selected
    def dependent_form
      if params[:dependent_id].present?
        @dependent = User.find_by(id: params[:dependent_id])
        @mode = :edit
      else
        @dependent = nil
        @mode = :new
      end

      render turbo_stream: turbo_stream.replace(
        'dependent_info_form',
        partial: 'admin/paper_applications/dependent_form',
        locals: { dependent: @dependent, mode: @mode }
      )
    end

    def recipient_preference
      recipient = resolve_notification_recipient_for_lookup(
        recipient_id: params[:id],
        email: params[:email]
      )

      render json: {
        found: recipient.present?,
        recipient_id: recipient&.id,
        communication_preference: recipient&.effective_communication_preference&.to_s
      }
    end

    # Server-rendered FPL data helper methods
    # These inject threshold data into HTML data attributes for client-side validation
    # See: app/services/income_threshold_calculation_service.rb for core FPL logic
    helper_method :fpl_thresholds_json, :fpl_modifier_value

    def fpl_thresholds_json
      return '{}' unless FeatureFlag.enabled?(:income_proof_required)

      thresholds = (1..8).to_h do |size|
        result = IncomeThresholdCalculationService.call(size)
        if result.success?
          [size.to_s, result.data[:base_fpl]]
        else
          [size.to_s, 0]
        end
      end
      thresholds.to_json
    end

    def fpl_modifier_value
      return 0 unless FeatureFlag.enabled?(:income_proof_required)

      result = IncomeThresholdCalculationService.call(1)
      if result.success?
        result.data[:modifier]
      else
        400
      end
    end

    def reject_for_income
      unless FeatureFlag.enabled?(:income_proof_required)
        redirect_to new_admin_paper_application_path, alert: 'Income rejection is not available when income collection is disabled.'
        return
      end

      constituent_params = build_constituent_params_for_notification
      notification_params = build_notification_params
      recipient = resolve_constituent_notification_recipient(constituent_params)

      if requested_letter_delivery?(notification_params) && !recipient.is_a?(User)
        handle_error_response(
          html_redirect_path: admin_applications_path,
          error_message: 'Cannot queue a mailed letter without an existing constituent account.'
        )
        return
      end

      # Send rejection notification without creating an application
      ApplicationNotificationsMailer.income_threshold_exceeded(
        recipient,
        notification_params
      ).deliver_later

      # Log the rejection event (no application to reference)
      log_income_threshold_rejection(constituent_params, notification_params)

      handle_success_response(
        html_redirect_path: admin_applications_path,
        html_message: rejection_success_message(notification_params),
        turbo_message: rejection_success_message(notification_params),
        turbo_redirect_path: admin_applications_path
      )
    end

    def send_rejection_notification
      unless FeatureFlag.enabled?(:income_proof_required)
        redirect_to admin_applications_path, alert: 'Income rejection is not available when income collection is disabled.'
        return
      end

      constituent_params = build_constituent_params_for_notification
      notification_params = build_notification_params
      recipient = resolve_constituent_notification_recipient(constituent_params)

      if requested_letter_delivery?(notification_params) && !recipient.is_a?(User)
        handle_error_response(
          html_redirect_path: admin_applications_path,
          error_message: 'Cannot queue a mailed letter without an existing constituent account.'
        )
        return
      end

      ApplicationNotificationsMailer.income_threshold_exceeded(
        recipient,
        notification_params
      ).deliver_later

      success_message = rejection_success_message(notification_params)

      handle_success_response(
        html_redirect_path: admin_applications_path,
        html_message: success_message,
        turbo_message: success_message,
        turbo_redirect_path: admin_applications_path
      )
    end

    private

    def calculate_income_threshold(household_size)
      threshold_result = IncomeThresholdCalculationService.new(household_size).call
      threshold_result.success? ? threshold_result.data[:threshold] : 0
    end

    def calculate_income_threshold_from_params(notification_params)
      household_size = notification_params['household_size'] || notification_params[:household_size]
      calculate_income_threshold(household_size)
    end

    def log_audit_event(application)
      AuditEventService.log(
        action: 'application_rejected_income_threshold',
        actor: Current.user,
        auditable: application,
        metadata: audit_metadata(application)
      )
    end

    def log_income_threshold_rejection(constituent_params, notification_params)
      AuditEventService.log(
        action: 'income_threshold_rejection_no_application',
        actor: Current.user,
        auditable: nil, # No application was created
        metadata: {
          constituent_name: "#{constituent_params['first_name']} #{constituent_params['last_name']}",
          constituent_email: constituent_params['email'],
          income: notification_params['annual_income'],
          household_size: notification_params['household_size'],
          threshold: calculate_income_threshold_from_params(notification_params)
        }
      )
    end

    def audit_metadata(application)
      {
        income: application.annual_income,
        household_size: application.household_size,
        threshold: calculate_income_threshold(application.household_size)
      }
    end

    def handle_service_failure(service, existing_application = nil)
      error_msg = if service.errors.any?
                    service.errors.join('; ')
                  else
                    'An unexpected error occurred.'
                  end
      operation_context = Rails.env.test? ? '[TEST_BUSINESS_LOGIC] ' : '[ADMIN_OPERATION] '
      Rails.logger.error "#{operation_context}Paper application operation failed: #{error_msg}"

      repopulate_form_data(service, existing_application)

      handle_error_response(
        html_render_action: (existing_application ? :edit : :new),
        error_message: error_msg
      )
    end

    def repopulate_form_data(service, existing_application)
      submitted_params = build_submitted_params

      # Get or build constituent with submitted data
      constituent = service.constituent || existing_application&.user || Constituent.new

      # Re-render the form with the submitted values, even for persisted records.
      constituent.assign_attributes(submitted_params[:constituent]) if submitted_params[:constituent].present?

      # Get or build application with submitted data
      application = service.application || existing_application || Application.new
      application.assign_attributes(submitted_params[:application]) if submitted_params[:application].present?

      @paper_application = {
        application: application,
        constituent: constituent,
        guardian_user_for_app: service.guardian_user_for_app,
        applicant_attributes: submitted_params[:applicant_attributes] || {},
        guardian_attributes: submitted_params[:guardian_attributes] || {},
        submitted_params: submitted_params,
        show_create_new_adult: show_create_new_adult_from?(submitted_params)
      }
    end

    def build_submitted_params
      params.permit(
        :applicant_type, :relationship_type, :guardian_id, :dependent_id,
        :existing_constituent_id, :contact_info_mode, :contact_info_verified,
        :email_strategy, :phone_strategy, :address_strategy,
        :use_guardian_email, :use_guardian_phone, :use_guardian_address,
        application: APPLICATION_FIELDS,
        applicant_attributes: USER_DISABILITY_FIELDS,
        constituent: (USER_BASE_FIELDS + DEPENDENT_BASE_FIELDS + USER_DISABILITY_FIELDS),
        guardian_attributes: (USER_BASE_FIELDS + USER_DISABILITY_FIELDS)
      ).to_h.with_indifferent_access
    end

    def show_create_new_adult_from?(submitted_params)
      submitted_params[:applicant_type] == 'self' &&
        submitted_params[:existing_constituent_id].blank? &&
        submitted_params[:constituent].present?
    end

    def log_file_and_form_params
      Rails.logger.debug { "income_proof present: #{params[:income_proof].present?}" }
      Rails.logger.debug { "residency_proof present: #{params[:residency_proof].present?}" }
      nil unless params[:income_proof].present? && params[:income_proof].respond_to?(:original_filename)
    end

    def generate_success_message(application)
      if application.proof_reviews.where(status: :rejected).any?
        rejected_proofs = []
        rejected_proofs << 'income' if application.income_proof_status_rejected?
        rejected_proofs << 'residency' if application.residency_proof_status_rejected?

        if rejected_proofs.any?
          message = "Paper application successfully submitted with #{rejected_proofs.length} rejected "
          message += rejected_proofs.length == 1 ? 'proof' : 'proofs'
          message += ": #{rejected_proofs.join(' and ')}. Notifications will be sent."
          return message
        end
      end
      'Paper application successfully submitted.'
    end

    # Main method to construct parameters for the PaperApplicationService
    def paper_application_processing_params
      permitted = permitted_paper_params

      service_params = base_params_from(permitted)
      apply_strategies!(service_params, permitted)
      disability_attrs = merge_application_and_disabilities!(service_params, permitted)
      merge_user_params!(service_params, permitted, disability_attrs)
      add_proof_params_from!(service_params, permitted)

      Rails.logger.debug { "Final service params: #{service_params.inspect}" }
      service_params
    end

    def inferred_dependent_application_from(permitted)
      (permitted[:guardian_id].present? || permitted[:guardian_attributes].present?) &&
        permitted.dig(:constituent, :first_name).present?
    end

    def permitted_paper_params
      params.permit(
        :relationship_type, :guardian_id, :dependent_id, :applicant_type, :existing_constituent_id,
        :contact_info_mode, :contact_info_verified,
        :email_strategy, :phone_strategy, :address_strategy,
        :use_guardian_email, :use_guardian_phone, :use_guardian_address,
        :income_proof_action, :income_proof, :income_proof_signed_id,
        :income_proof_rejection_reason, :income_proof_custom_rejection_reason,
        :residency_proof_action, :residency_proof, :residency_proof_signed_id,
        :residency_proof_rejection_reason, :residency_proof_custom_rejection_reason,
        :medical_certification_action, :medical_certification, :medical_certification_signed_id,
        :medical_certification_rejection_reason, :medical_certification_custom_rejection_reason,
        :no_medical_provider_information,
        application: APPLICATION_FIELDS,
        applicant_attributes: USER_DISABILITY_FIELDS,
        constituent: (USER_BASE_FIELDS + DEPENDENT_BASE_FIELDS + USER_DISABILITY_FIELDS),
        guardian_attributes: (USER_BASE_FIELDS + USER_DISABILITY_FIELDS)
      ).to_h.with_indifferent_access
    end

    def base_params_from(permitted)
      base = permitted.slice(
        :relationship_type, :guardian_id, :dependent_id, :no_medical_provider_information,
        :existing_constituent_id, :contact_info_mode, :contact_info_verified
      )
      base[:applicant_type] = compute_applicant_type(permitted)
      base
    end

    def compute_applicant_type(permitted)
      return 'dependent' if inferred_dependent_application_from(permitted)

      raw = permitted[:applicant_type].presence || 'self'

      # Defensive: if "guardian" was submitted but no guardian/dependent IDs present,
      # the admin selected the adult radio (legacy value bug). Normalize to "self".
      return 'self' if raw == 'guardian' && permitted[:guardian_id].blank? && permitted[:dependent_id].blank?

      raw
    end

    def apply_strategies!(service_params, permitted)
      dependent = service_params[:applicant_type] == 'dependent'

      service_params[:email_strategy] = determine_strategy(permitted, :email_strategy, :use_guardian_email, dependent)
      service_params[:phone_strategy] = determine_strategy(permitted, :phone_strategy, :use_guardian_phone, dependent)
      service_params[:address_strategy] = determine_strategy(permitted, :address_strategy, :use_guardian_address, dependent)
    end

    def determine_strategy(permitted, strategy_key, checkbox_key, dependent)
      return permitted[strategy_key] if permitted[strategy_key].present?
      return 'dependent' unless dependent

      to_boolean(permitted[checkbox_key]) ? 'guardian' : 'dependent'
    end

    def merge_application_and_disabilities!(service_params, permitted)
      app = (permitted[:application] || {}).dup
      disability_attrs = (permitted[:applicant_attributes] || {}).dup
      app[:self_certify_disability] = disability_attrs.delete(:self_certify_disability) if disability_attrs.key?(:self_certify_disability)
      service_params[:application] = app
      disability_attrs
    end

    def merge_user_params!(service_params, permitted, disability_attrs)
      constituent_attrs = (permitted[:constituent] || {}).dup
      service_params[:constituent] = constituent_attrs.deep_merge(disability_attrs)

      return unless service_params[:applicant_type] == 'dependent'

      service_params[:new_guardian_attributes] = permitted[:guardian_attributes] if service_params[:guardian_id].blank? && permitted[:guardian_attributes].present?
    end

    def add_proof_params_from!(service_params, permitted)
      %w[income residency].each do |type|
        action_key = "#{type}_proof_action"
        file_key   = "#{type}_proof"
        signed_key = "#{type}_proof_signed_id"
        reason_key        = "#{type}_proof_rejection_reason"
        custom_reason_key = "#{type}_proof_custom_rejection_reason"

        service_params[action_key] = permitted[action_key]
        file_val = permitted[file_key]
        signed_val = permitted[signed_key]
        service_params[file_key] = file_val if file_val.present?
        service_params[signed_key] = signed_val if signed_val.present?
        service_params[reason_key] = permitted[reason_key]
        service_params[custom_reason_key] = permitted[custom_reason_key]
      end

      # Handle medical certification (uses different naming convention)
      service_params[:medical_certification_action] = permitted[:medical_certification_action]
      file_val = permitted[:medical_certification]
      signed_val = permitted[:medical_certification_signed_id]
      service_params[:medical_certification] = file_val if file_val.present?
      service_params[:medical_certification_signed_id] = signed_val if signed_val.present?
      service_params[:medical_certification_rejection_reason] = permitted[:medical_certification_rejection_reason]
      service_params[:medical_certification_custom_rejection_reason] = permitted[:medical_certification_custom_rejection_reason]
    end

    # Translate checkbox UI to email strategy parameter
    def determine_email_strategy
      # Check for direct strategy parameter first (for API/test compatibility)
      return params[:email_strategy] if params[:email_strategy].present?

      # For dependent applications, check the "use guardian's email" checkbox
      if params[:applicant_type] == 'dependent' || inferred_dependent_application?
        use_guardian_email = to_boolean(params[:use_guardian_email])
        return use_guardian_email ? 'guardian' : 'dependent'
      end

      # For self-applications, always use their own email
      'dependent'
    end

    # Translate checkbox UI to phone strategy parameter
    def determine_phone_strategy
      # Check for direct strategy parameter first (for API/test compatibility)
      return params[:phone_strategy] if params[:phone_strategy].present?

      # For dependent applications, check the "use guardian's phone" checkbox
      if params[:applicant_type] == 'dependent' || inferred_dependent_application?
        use_guardian_phone = to_boolean(params[:use_guardian_phone])
        return use_guardian_phone ? 'guardian' : 'dependent'
      end

      # For self-applications, always use their own phone
      'dependent'
    end

    # Translate checkbox UI to address strategy parameter
    def determine_address_strategy
      # Check for direct strategy parameter first (for API/test compatibility)
      return params[:address_strategy] if params[:address_strategy].present?

      # For dependent applications, check the "same as guardian's address" checkbox
      if params[:applicant_type] == 'dependent' || inferred_dependent_application?
        use_guardian_address = to_boolean(params[:use_guardian_address])
        return use_guardian_address ? 'guardian' : 'dependent'
      end

      # For self-applications, always use their own address
      'dependent'
    end

    # Helper to determine if this is a dependent application based on guardian presence
    def inferred_dependent_application?
      (params[:guardian_id].present? || params[:guardian_attributes].present?) &&
        params[:constituent].present? && params[:constituent].is_a?(ActionController::Parameters) && params[:constituent][:first_name].present?
    end

    def build_constituent_params_for_notification
      constituent_params = params.permit(
        :id, :first_name, :last_name, :email, :dependent_email, :phone, :communication_preference
      ).to_h

      constituent_params['email'] = normalized_contact_email(constituent_params['email']) ||
                                    normalized_contact_email(constituent_params['dependent_email'])
      constituent_params['dependent_email'] = normalized_contact_email(constituent_params['dependent_email'])
      constituent_params
    end

    def build_notification_params
      params.permit(:household_size, :annual_income, :communication_preference, :additional_notes).to_h
    end

    def resolve_constituent_notification_recipient(constituent_params)
      constituent_id = constituent_params['id'].presence
      recipient = User.find_by(id: constituent_id) if constituent_id
      return recipient if recipient.present?

      constituent_email = normalized_contact_email(constituent_params['email'])
      return constituent_params if constituent_email.blank?

      find_user_by_contact_email(constituent_email) || constituent_params
    end

    def resolve_notification_recipient_for_lookup(recipient_id:, email:)
      user = User.find_by(id: recipient_id) if recipient_id.present?
      return user if user.present?

      normalized_email = normalized_contact_email(email)
      return nil if normalized_email.blank?

      find_user_by_contact_email(normalized_email)
    end

    def find_user_by_contact_email(email)
      normalized_email = normalized_contact_email(email)
      return nil if normalized_email.blank?

      User.find_by_email(normalized_email) || User.find_by(dependent_email: normalized_email)
    end

    def normalized_contact_email(value)
      User.normalize_email(value)
    end

    def requested_letter_delivery?(source_params)
      notification_delivery_preference(source_params) == 'letter'
    end

    def notification_delivery_preference(source_params)
      preference = source_params[:communication_preference] || source_params['communication_preference']
      preference.to_s.strip.downcase.presence
    end

    def rejection_success_message(source_params)
      requested_letter_delivery?(source_params) ? 'Rejection letter has been queued for printing' : 'Rejection notification has been sent'
    end

    def send_medical_certification_notification_if_needed(application)
      has_provider_info = application.medical_provider_name.present? ||
                          application.medical_provider_email.present? ||
                          application.medical_provider_phone.present?
      is_rejected = application.medical_certification_status_rejected?

      # If provider info exists AND certification is rejected for reason other than not present, notify the provider
      if has_provider_info && is_rejected && application.medical_certification_rejection_reason != 'none_provided'
        MedicalProviderMailer.certification_revision_needed(application).deliver_later
        return
      end

      # If nothing is attached (no provider info AND a rejected certification), notify the constituent
      return if has_provider_info || !is_rejected

      ApplicationNotificationsMailer.medical_certification_not_provided(application).deliver_later
    rescue StandardError => e
      Rails.logger.error("Failed to send medical certification notification for application #{application&.id}: #{e.message}")
    end

    # NOTE: cast_boolean_params and cast_boolean_for are provided by the ParamCasting concern
    # The complex parameter casting is handled by cast_complex_boolean_params
  end
end
