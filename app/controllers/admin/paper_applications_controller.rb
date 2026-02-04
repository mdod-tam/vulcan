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
        constituent: Constituent.new # For dependent or self-applicant
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
        handle_success_response(
          html_redirect_path: admin_application_path(service.application),
          html_message: success_message,
          turbo_message: success_message,
          turbo_redirect_path: admin_application_path(service.application)
        )
      else
        Rails.logger.info "[PaperApplicationsController] Handling service failure, request format: #{request.format}"
        handle_service_failure(service)
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
        handle_success_response(
          html_redirect_path: admin_application_path(application),
          html_message: generate_success_message(application),
          turbo_message: generate_success_message(application),
          turbo_redirect_path: admin_application_path(application)
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

    # Server-rendered FPL data helper methods
    # These inject threshold data into HTML data attributes for client-side validation
    # See: app/services/income_threshold_calculation_service.rb for core FPL logic
    helper_method :fpl_thresholds_json, :fpl_modifier_value

    def fpl_thresholds_json
      # Generate FPL threshold data for JavaScript using IncomeThresholdCalculationService
      # Returns JSON string of base FPL values for household sizes 1-8
      thresholds = (1..8).to_h do |size|
        result = IncomeThresholdCalculationService.call(size)
        if result.success?
          [size.to_s, result.data[:base_fpl]]
        else
          [size.to_s, 0] # Fallback for failed calculations
        end
      end
      thresholds.to_json
    end

    def fpl_modifier_value
      # Get FPL modifier percentage via IncomeThresholdCalculationService
      # Returns the policy-configured modifier (e.g., 400 for 400% FPL)
      result = IncomeThresholdCalculationService.call(1)
      if result.success?
        result.data[:modifier]
      else
        400 # Default
      end
    end

    def reject_for_income
      # Build constituent params from form data for notification (no application created)
      constituent_params = build_constituent_params_for_notification
      notification_params = build_notification_params

      # Send rejection notification without creating an application
      ApplicationNotificationsMailer.income_threshold_exceeded(
        constituent_params,
        notification_params
      ).deliver_later

      # Log the rejection event (no application to reference)
      log_income_threshold_rejection(constituent_params, notification_params)

      handle_success_response(
        html_redirect_path: admin_applications_path,
        html_message: 'Application rejected due to income threshold. Rejection notification has been sent.',
        turbo_message: 'Application rejected due to income threshold. Rejection notification has been sent.',
        turbo_redirect_path: admin_applications_path
      )
    end

    def send_rejection_notification
      # Build constituent params from form data
      constituent_params = build_constituent_params_for_notification
      notification_params = build_notification_params

      notification_method = params[:communication_preference]

      if notification_method == 'letter'
        # For letter notifications, queue for printing
        # This would integrate with a print queue system
        handle_success_response(
          html_redirect_path: admin_applications_path,
          html_message: 'Rejection letter has been queued for printing',
          turbo_message: 'Rejection letter has been queued for printing',
          turbo_redirect_path: admin_application_path
        )
      else
        # For email notifications, send immediately
        ApplicationNotificationsMailer.income_threshold_exceeded(
          constituent_params,
          notification_params
        ).deliver_later

        handle_success_response(
          html_redirect_path: admin_applications_path,
          html_message: 'Rejection notification has been sent',
          turbo_message: 'Rejection notification has been sent',
          turbo_redirect_path: admin_applications_path
        )
      end
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
      @paper_application = {
        application: service.application || existing_application || Application.new,
        constituent: service.constituent || existing_application&.user || Constituent.new,
        guardian_user_for_app: service.guardian_user_for_app,
        submitted_params: build_submitted_params
      }
    end

    def build_submitted_params
      params.permit(
        :applicant_type, :relationship_type, :guardian_id, :dependent_id,
        :email_strategy, :phone_strategy, :address_strategy,
        :use_guardian_email, :use_guardian_phone, :use_guardian_address,
        application: APPLICATION_FIELDS,
        applicant_attributes: USER_DISABILITY_FIELDS,
        constituent: (USER_BASE_FIELDS + DEPENDENT_BASE_FIELDS + USER_DISABILITY_FIELDS),
        guardian_attributes: (USER_BASE_FIELDS + USER_DISABILITY_FIELDS)
      ).to_h.with_indifferent_access
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
        :relationship_type, :guardian_id, :dependent_id, :applicant_type,
        :email_strategy, :phone_strategy, :address_strategy,
        :use_guardian_email, :use_guardian_phone, :use_guardian_address,
        :income_proof_action, :income_proof, :income_proof_signed_id,
        :income_proof_rejection_reason, :income_proof_rejection_notes,
        :residency_proof_action, :residency_proof, :residency_proof_signed_id,
        :residency_proof_rejection_reason, :residency_proof_rejection_notes,
        :no_medical_provider_information,
        application: APPLICATION_FIELDS,
        applicant_attributes: USER_DISABILITY_FIELDS,
        constituent: (USER_BASE_FIELDS + DEPENDENT_BASE_FIELDS + USER_DISABILITY_FIELDS),
        guardian_attributes: (USER_BASE_FIELDS + USER_DISABILITY_FIELDS)
      ).to_h.with_indifferent_access
    end

    def base_params_from(permitted)
      base = permitted.slice(:relationship_type, :guardian_id, :dependent_id, :no_medical_provider_information)
      base[:applicant_type] = compute_applicant_type(permitted)
      base
    end

    def compute_applicant_type(permitted)
      # Dependent indicators (guardian + constituent data) take precedence
      return 'dependent' if inferred_dependent_application_from(permitted)

      # Use explicit value if provided, otherwise default to 'self'
      permitted[:applicant_type].presence || 'self'
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
        reason_key = "#{type}_proof_rejection_reason"
        notes_key  = "#{type}_proof_rejection_notes"

        service_params[action_key] = permitted[action_key]
        file_val = permitted[file_key]
        signed_val = permitted[signed_key]
        service_params[file_key] = file_val if file_val.present?
        service_params[signed_key] = signed_val if signed_val.present?
        service_params[reason_key] = permitted[reason_key]
        service_params[notes_key]  = permitted[notes_key]
      end
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
      # Simplified for notification, might need adjustment based on actual form fields for notification
      params.permit(:first_name, :last_name, :email, :phone).to_h
    end

    def build_notification_params
      params.permit(:household_size, :annual_income, :communication_preference, :additional_notes).to_h
    end

    # NOTE: cast_boolean_params and cast_boolean_for are provided by the ParamCasting concern
    # The complex parameter casting is handled by cast_complex_boolean_params
  end
end
