# frozen_string_literal: true

module Admin
  class PaperApplicationsController < Admin::BaseController
    include ParamCasting
    include TurboStreamResponseHandling
    before_action :cast_complex_boolean_params, only: %i[create update]

    USER_BASE_FIELDS = %i[
      first_name last_name email phone phone_type
      physical_address_1 physical_address_2 city state zip_code
      communication_preference
    ].freeze

    USER_DISABILITY_FIELDS = %i[
      self_certify_disability hearing_disability vision_disability speech_disability
      mobility_disability cognition_disability
    ].freeze

    DEPENDENT_BASE_FIELDS = %i[
      first_name last_name date_of_birth
      physical_address_1 physical_address_2 city state zip_code
      dependent_email dependent_phone
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

      if service.create
        handle_success_response(
          html_redirect_path: admin_application_path(service.application),
          html_message: generate_success_message(service.application),
          turbo_message: generate_success_message(service.application)
        )
      else
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
          turbo_message: generate_success_message(application)
        )
      else
        handle_service_failure(service, application)
      end
    end

    def fpl_thresholds
      thresholds = {}
      (1..8).each do |size|
        thresholds[size] = Policy.get("fpl_#{size}_person").to_i
      end
      modifier = Policy.get('fpl_modifier_percentage').to_i
      render json: { thresholds: thresholds, modifier: modifier }
    end

    def send_rejection_notification
      constituent_params_for_notification = build_constituent_params_for_notification
      notification_params = build_notification_params

      communication_preference = params[:notification_method] || params[:communication_preference]

      if communication_preference == 'email'
        ApplicationNotificationsMailer.income_threshold_exceeded(constituent_params_for_notification, notification_params)
                                      .deliver_later
        handle_success_response(
          html_redirect_path: admin_applications_path,
          html_message: 'Rejection notification has been sent.',
          turbo_message: 'Rejection notification has been sent.'
        )
      elsif communication_preference == 'letter'
        handle_success_response(
          html_redirect_path: admin_applications_path,
          html_message: 'Rejection letter has been queued for printing.',
          turbo_message: 'Rejection letter has been queued for printing.'
        ) # Assuming a letter service exists
      else
        handle_error_response(
          html_redirect_path: admin_applications_path,
          error_message: 'Invalid communication preference for rejection notification.'
        )
      end
    end

    private

    def handle_service_failure(service, existing_application = nil)
      error_msg = if service.errors.any?
                    service.errors.join('; ')
                  else
                    'An unexpected error occurred.'
                  end
      Rails.logger.error "Paper application operation failed: #{error_msg}"

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
      params.to_unsafe_h.slice(
        :applicant_type, :relationship_type, :guardian_id, :dependent_id,
        :guardian_attributes, :applicant_attributes, :application, :constituent,
        :email_strategy, :phone_strategy, :address_strategy,
        :use_guardian_email, :use_guardian_phone, :use_guardian_address
      )
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
      service_params = build_base_service_params
      add_application_params(service_params)
      add_user_params(service_params)
      add_proof_params(service_params)

      Rails.logger.debug { "Final service params: #{service_params.inspect}" }
      service_params
    end

    def build_base_service_params
      current_applicant_type = determine_applicant_type

      service_params = params.permit(:relationship_type, :guardian_id, :dependent_id)
                             .to_h.with_indifferent_access
      service_params[:applicant_type] = current_applicant_type
      service_params[:email_strategy] = determine_email_strategy
      service_params[:phone_strategy] = determine_phone_strategy
      service_params[:address_strategy] = determine_address_strategy

      service_params
    end

    def determine_applicant_type
      # Infer applicant_type if guardian_id OR guardian_attributes is present and constituent data exists
      return params[:applicant_type] if params[:applicant_type].present? && !inferred_dependent_application?

      inferred_dependent_application? ? 'dependent' : params[:applicant_type]
    end

    def add_application_params(service_params)
      service_params[:application] = permitted_application_attributes if params[:application].present?
      service_params[:application] ||= {}

      # Handle applicant disability attributes
      applicant_attrs = permitted_applicant_disability_attributes
      service_params[:application][:self_certify_disability] = applicant_attrs.delete(:self_certify_disability) if applicant_attrs.key?(:self_certify_disability)

      service_params[:applicant_disability_attrs] = applicant_attrs
    end

    def add_user_params(service_params)
      if service_params[:applicant_type] == 'dependent'
        add_dependent_params(service_params)
      else
        add_self_applicant_params(service_params)
      end
    end

    def add_dependent_params(service_params)
      # The APPLICANT is the DEPENDENT
      constituent_attrs = params[:constituent].present? ? permitted_constituent_attributes : {}
      applicant_attrs = service_params.delete(:applicant_disability_attrs) || {}
      service_params[:constituent] = constituent_attrs.deep_merge(applicant_attrs)

      # Handle the Guardian separately
      return unless service_params[:guardian_id].blank? && params[:guardian_attributes].present?

      service_params[:new_guardian_attributes] = permitted_guardian_attributes
    end

    def add_self_applicant_params(service_params)
      # The APPLICANT is the self-applying adult
      applicant_attrs = service_params.delete(:applicant_disability_attrs) || {}

      service_params[:constituent] = if params[:constituent].present? && params.expect(constituent: [:first_name]).present?
                                       permitted_constituent_attributes.deep_merge(applicant_attrs)
                                     elsif params[:guardian_attributes].present?
                                       # "Create New Guardian" form was filled for self-applicant
                                       permitted_guardian_attributes.deep_merge(applicant_attrs)
                                     else
                                       # Fallback: ensure only disability flags are passed
                                       applicant_attrs
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
        params[:constituent].present? && params.expect(constituent: [:first_name]).present?
    end

    def permitted_guardian_attributes
      if params[:guardian_attributes].present?
        params.expect(guardian_attributes: [*USER_BASE_FIELDS, *USER_DISABILITY_FIELDS])
              .to_h.with_indifferent_access
      else
        {}
      end
    end

    def permitted_constituent_attributes
      # For constituents (including dependents), permit all standard user fields plus dependent-specific fields
      permitted_fields = USER_BASE_FIELDS + DEPENDENT_BASE_FIELDS + USER_DISABILITY_FIELDS
      params.expect(constituent: [*permitted_fields]).to_h.with_indifferent_access
    end

    def permitted_applicant_disability_attributes
      if params[:applicant_attributes].present?
        params.expect(applicant_attributes: [*USER_DISABILITY_FIELDS]).to_h.with_indifferent_access
      else
        {}
      end
    end

    def permitted_application_attributes
      params.expect(application: [*APPLICATION_FIELDS]).to_h.with_indifferent_access
    end

    def add_proof_params(service_params)
      # ... (original add_proof_params logic)
      %w[income residency].each do |type|
        action_key = "#{type}_proof_action"
        service_params[action_key] = params[action_key]

        file_key = "#{type}_proof"
        service_params[file_key] = params[file_key] if params[file_key].present?

        signed_id_key = "#{type}_proof_signed_id"
        service_params[signed_id_key] = params[signed_id_key] if params[signed_id_key].present?

        service_params["#{type}_proof_rejection_reason"] = params["#{type}_proof_rejection_reason"]
        service_params["#{type}_proof_rejection_notes"] = params["#{type}_proof_rejection_notes"]
      end
    end

    def build_constituent_params_for_notification
      # Simplified for notification, might need adjustment based on actual form fields for notification
      params.permit(:first_name, :last_name, :email, :phone).to_h
    end

    def build_notification_params
      params.permit(:household_size, :annual_income, :communication_preference, :additional_notes).to_h
    end

    # NOTE: cast_boolean_params and cast_boolean_for are now provided by the ParamCasting concern
    # The complex parameter casting is handled by cast_complex_boolean_params
  end
end
