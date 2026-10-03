# frozen_string_literal: true

module Admin
  class PaperApplicationsController < Admin::BaseController
    include ParamCasting
    include TurboStreamResponseHandling
    include PaperQuickCreatePortalMarkers

    before_action :cast_complex_boolean_params, only: %i[create]

    USER_BASE_FIELDS = %i[
      first_name middle_initial last_name email phone phone_type
      physical_address_1 physical_address_2 city state zip_code
      communication_preference locale date_of_birth
      preferred_means_of_communication referral_source newsletter_signup
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

    # The controller owns the allowlist for proof inputs restored to staff.
    # Medical certification uses approved where other proof groups use accept.
    PROOF_FILE_GROUPS = {
      income_proof_action: 'Income proof',
      residency_proof_action: 'Residency proof',
      id_proof_action: 'Identity proof',
      medical_certification_action: 'Disability certification'
    }.freeze
    ACTIONS_NEEDING_A_FILE = %w[accept approved upload_only].freeze

    PROOF_WORKFLOW_FIELDS = %i[
      income_proof_action residency_proof_action id_proof_action medical_certification_action
      income_proof_rejection_reason income_proof_custom_rejection_reason
      residency_proof_rejection_reason residency_proof_custom_rejection_reason
      id_proof_rejection_reason id_proof_custom_rejection_reason
      medical_certification_rejection_reason medical_certification_custom_rejection_reason
    ].freeze

    APPLICATION_FIELDS = %i[
      household_size annual_income maryland_resident self_certify_disability
      medical_provider_name medical_provider_phone medical_provider_fax
      medical_provider_email terms_accepted information_verified
      medical_release_authorized
      alternate_contact_name alternate_contact_phone alternate_contact_email alternate_contact_relationship_type
    ].freeze

    def new
      @paper_application = {
        application: Application.new,
        guardian_attributes: Users::Constituent.new,
        applicant_attributes: {},
        constituent: Constituent.new,
        show_create_new_adult: false
      }

      @show_create_guardian_form = params[:show_create_guardian_form].present?
      @applicant_type = params[:applicant_type].presence || (@show_create_guardian_form ? 'dependent' : 'self')
      @restored_from_submission = false
      @selected_guardian = nil
      @selected_dependent = nil
    end

    # Already-open PR 205 forms treat clear as permission to submit.
    # Only create adjudicates identity. This response grants no decision.
    def identity_review
      response.headers['Cache-Control'] = 'no-store'
      render json: { state: 'clear' }
    end

    def create
      log_file_and_form_params
      service_params = paper_application_processing_params

      service = Applications::PaperApplicationService.new(
        params: service_params,
        admin: current_user,
        quick_created_portal_user_ids: quick_created_portal_user_ids
      )

      service_result = service.create

      if service_result
        # Confirm the commit before generate_success_message queries proof_reviews.
        # Another database error must not replace the warning with a 500 response.
        return handle_unconfirmed_commit_response(service.warning_message) unless service.commit_confirmed?

        # Retain quick-create markers until commit is confirmed.
        # Unconfirmed writes skip the notices and access warnings that consume these markers.
        clear_quick_created_portal_user_markers!

        success_message = generate_success_message(service.application)
        # Surface callback and follow-up warnings as well as reconciliation failures.
        if service.warning_message.present?
          handle_reconciliation_warning_response(
            application: service.application,
            success_message: success_message,
            warning_message: service.warning_message,
            commit_confirmed: true
          )
        else
          handle_success_response(
            html_redirect_path: admin_application_path(service.application),
            html_message: success_message,
            turbo_message: success_message,
            turbo_redirect_path: admin_application_path(service.application)
          )
        end
      else
        Rails.logger.info "[PaperApplicationsController] Handling service failure, request format: #{request.format}"

        # The service owns commit classification. A false result restores the form with the error.
        # Do not infer commit state from service.application.persisted?.
        handle_service_failure(service)
      end
    end

    def dependent_form
      if params[:dependent_id].present?
        @dependent = User.find_by(id: params[:dependent_id])
        @mode = :edit
      else
        @dependent = nil
        @mode = :new
      end

      # Update the frame contents so later dependent selections can reuse the same Turbo Frame.
      render turbo_stream: turbo_stream.update(
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

    # Client validation receives FPL data from IncomeThresholdCalculationService.
    # See app/services/income_threshold_calculation_service.rb.
    helper_method :fpl_thresholds_json, :fpl_modifier_value

    def fpl_thresholds_json
      return '{}' unless FeatureFlag.income_proof_required?

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
      return 0 unless FeatureFlag.income_proof_required?

      result = IncomeThresholdCalculationService.call(1)
      if result.success?
        result.data[:modifier]
      else
        400
      end
    end

    def reject_for_income
      unless FeatureFlag.income_proof_required?
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

      # Income rejection sends a notice without creating an application.
      ApplicationNotificationsMailer.income_threshold_exceeded(
        recipient,
        notification_params
      ).deliver_later

      # No application exists to own this audit event.
      log_income_threshold_rejection(constituent_params, notification_params)

      handle_success_response(
        html_redirect_path: admin_applications_path,
        html_message: rejection_success_message(notification_params),
        turbo_message: rejection_success_message(notification_params),
        turbo_redirect_path: admin_applications_path
      )
    end

    def send_rejection_notification
      unless FeatureFlag.income_proof_required?
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

    # Avoid record reads after failed commit verification.
    # Route to the list with a warning because application creation remains unconfirmed.
    def handle_unconfirmed_commit_response(warning_message)
      alert = warning_message.presence ||
              'The application may have been created, but that could not be confirmed. Check the ' \
              'applications list before entering it again -- submitting again could create a duplicate.'

      respond_to do |format|
        format.html { redirect_to admin_applications_path, flash: { alert: alert } }
        format.turbo_stream do
          redirect_to admin_applications_path, status: :see_other, flash: { alert: alert }
        end
      end
    end

    def handle_reconciliation_warning_response(application:, success_message:, warning_message:, commit_confirmed: true)
      # Keep the guard for callers that supply an unconfirmed commit.
      return handle_unconfirmed_commit_response(warning_message) unless commit_confirmed

      respond_to do |format|
        format.html do
          redirect_to admin_application_path(application),
                      flash: { notice: success_message, alert: warning_message }
        end

        format.turbo_stream do
          redirect_to admin_application_path(application),
                      status: :see_other,
                      flash: { notice: success_message, alert: warning_message }
        end
      end
    end

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
        auditable: nil,
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

      preserve_multipart_uploads
      repopulate_form_data(service, existing_application)

      handle_error_response(
        html_render_action: (existing_application ? :edit : :new),
        error_message: error_msg
      )
    end

    def preserve_multipart_uploads
      PROOF_FILE_GROUPS.each_key do |action|
        key = action.to_s.delete_suffix('_action')
        upload = params[key]
        next unless upload.is_a?(ActionDispatch::Http::UploadedFile)

        upload.rewind
        blob = ActiveStorage::Blob.create_and_upload!(
          io: upload.tempfile, filename: upload.original_filename, content_type: upload.content_type
        )
        params["#{key}_signed_id"] = blob.signed_id
      end
    end

    def repopulate_form_data(service, existing_application)
      submitted_params = build_submitted_params
      @identity_review = service.identity_review
      @uploaded_proofs = restored_uploads(submitted_params)

      constituent = rebuilt_constituent(service, existing_application, submitted_params)
      application = rebuilt_application(service, existing_application, submitted_params)

      restore_applicant_branch_state(submitted_params)

      @paper_application = {
        application: application,
        constituent: constituent,
        guardian_user_for_app: service.guardian_user_for_app,
        applicant_attributes: submitted_params[:applicant_attributes] || {},
        guardian_attributes: rebuilt_guardian_attributes(submitted_params),
        submitted_params: submitted_params,
        show_create_new_adult: show_create_new_adult_from?(submitted_params)
      }
    end

    # fields_for requires model readers. Rebuild a Constituent instead of passing the submitted hash.
    def rebuilt_guardian_attributes(submitted_params)
      submitted = submitted_params[:guardian_attributes]
      return Users::Constituent.new if submitted.blank?

      Users::Constituent.new.tap { |guardian| guardian.assign_attributes(submitted) }
    end

    def rebuilt_constituent(service, existing_application, submitted_params)
      constituent = service.constituent || existing_application&.user || Constituent.new
      # Submitted values take precedence over persisted values on a retry.
      constituent.assign_attributes(submitted_params[:constituent]) if submitted_params[:constituent].present?
      # The form submits disability flags under applicant_attributes, but the user owns these columns.
      # Exclude self_certify_disability, which belongs to Application.
      constituent.assign_attributes(user_owned_disability_attributes(submitted_params))
      constituent
    end

    def rebuilt_application(service, existing_application, submitted_params)
      application = service.application || existing_application || Application.new
      application.assign_attributes(submitted_params[:application]) if submitted_params[:application].present?
      # The form submits self_certify_disability under applicant_attributes, but Application owns the column.
      # Restore it from the submission even when constituent processing fails before an application exists.
      certification = submitted_self_certification(submitted_params)
      application.self_certify_disability = certification unless certification.nil?
      application
    end

    # Restore the branch before its guardian and dependent controls render.
    def restore_applicant_branch_state(submitted_params)
      # Locked radios are omitted from retry submissions. Infer the branch from the guardian selection, as the writer
      # does.
      @applicant_type = submitted_params[:applicant_type].presence ||
                        (inferred_dependent_application_from(submitted_params) ? 'dependent' : 'self')
      @show_create_guardian_form = submitted_params[:show_create_guardian_form].present? ||
                                   creating_guardian_inline?(submitted_params)
      # Prevent the adult picker from overwriting submitted corrections with on-file values.
      @restored_from_submission = true
      # The guardian picker populates this display only on selection. Supply the on-file record for retry rendering.
      @selected_guardian = User.find_by(id: submitted_params[:guardian_id])
      # The identity banner must name the existing dependent that the next POST will reuse.
      @selected_dependent = User.find_by(id: submitted_params[:dependent_id])
      @proofs_needing_reattachment = proof_groups_needing_reattachment(submitted_params)
    end

    # Preserve available signed uploads across validation and identity review.
    def restored_uploads(submitted)
      %w[income_proof residency_proof id_proof medical_certification].each_with_object({}) do |key, uploads|
        signed_id = submitted["#{key}_signed_id"]
        next submitted.delete("#{key}_signed_id") unless signed_id.is_a?(String) && signed_id.present?

        blob = ActiveStorage::Blob.find_signed(signed_id)
        if blob && blob.created_at > CleanupUnattachedUploadsJob::RETENTION.ago && !blob.attachments.exists?
          uploads[key] = blob
        else
          submitted.delete("#{key}_signed_id")
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        submitted.delete("#{key}_signed_id")
      end
    end

    def proof_groups_needing_reattachment(submitted_params)
      PROOF_FILE_GROUPS.filter_map do |field, label|
        key = field.to_s.delete_suffix('_action')
        label if ACTIONS_NEEDING_A_FILE.include?(submitted_params[field]) && !@uploaded_proofs&.key?(key)
      end
    end

    def creating_guardian_inline?(submitted_params)
      @applicant_type == 'dependent' &&
        submitted_params[:guardian_attributes].present? &&
        submitted_params[:guardian_id].blank?
    end

    # Absent input returns nil so a fresh form keeps its existing self-certification value.
    def submitted_self_certification(submitted_params)
      submitted = submitted_params[:applicant_attributes]
      return nil if submitted.blank?

      value = submitted.to_h.symbolize_keys[:self_certify_disability]
      value.nil? ? nil : ActiveModel::Type::Boolean.new.cast(value)
    end

    def user_owned_disability_attributes(submitted_params)
      submitted = submitted_params[:applicant_attributes]
      return {} if submitted.blank?

      submitted.to_h.symbolize_keys.slice(*(USER_DISABILITY_FIELDS & Constituent.column_names.map(&:to_sym)))
    end

    def build_submitted_params
      params.permit(
        :applicant_type, :relationship_type, :guardian_id, :dependent_id,
        :existing_constituent_id, :identity_review_receipt, :identity_candidate_id, :identity_determination,
        :identity_rationale, :contact_info_mode, :contact_info_verified,
        :no_email_address, :no_phone_number,
        :guardian_no_email_address, :guardian_no_phone_number,
        :email_strategy, :phone_strategy, :address_strategy,
        :use_guardian_email, :use_guardian_phone, :use_guardian_address,
        # Proof decisions are workflow inputs, not model attributes. Restore each action with its rejection reason and
        # custom text.
        *PROOF_WORKFLOW_FIELDS,
        :income_proof_signed_id, :residency_proof_signed_id, :id_proof_signed_id, :medical_certification_signed_id,
        # Restore these flags to keep provider and income requirements suppressed on retry.
        :no_medical_provider_information, :no_income_information, :show_create_guardian_form,
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

    def paper_application_processing_params
      permitted = permitted_paper_params

      service_params = base_params_from(permitted)
      apply_strategies!(service_params, permitted)
      disability_attrs = merge_application_and_disabilities!(service_params, permitted)
      merge_user_params!(service_params, permitted, disability_attrs)
      add_proof_params_from!(service_params, permitted)

      service_params
    end

    def inferred_dependent_application_from(permitted)
      return false if permitted[:guardian_id].blank? && permitted[:guardian_attributes].blank?

      # Existing-dependent forms omit identity fields. dependent_id can identify this branch without a submitted name.
      permitted[:dependent_id].present? || permitted.dig(:constituent, :first_name).present?
    end

    def permitted_paper_params
      params.permit(
        :relationship_type, :guardian_id, :dependent_id, :applicant_type, :existing_constituent_id,
        :identity_review_receipt, :identity_candidate_id, :identity_determination, :identity_rationale, :contact_info_mode, :contact_info_verified,
        :email_strategy, :phone_strategy, :address_strategy,
        :use_guardian_email, :use_guardian_phone, :use_guardian_address,
        :no_email_address,
        :no_phone_number,
        :guardian_no_email_address,
        :guardian_no_phone_number,
        :income_proof_action, :income_proof, :income_proof_signed_id,
        :income_proof_rejection_reason, :income_proof_custom_rejection_reason,
        :residency_proof_action, :residency_proof, :residency_proof_signed_id,
        :residency_proof_rejection_reason, :residency_proof_custom_rejection_reason,
        :id_proof_action, :id_proof, :id_proof_signed_id,
        :id_proof_rejection_reason, :id_proof_custom_rejection_reason,
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
        :existing_constituent_id, :identity_review_receipt, :identity_candidate_id, :identity_determination,
        :identity_rationale, :contact_info_mode, :contact_info_verified,
        :no_email_address, :no_phone_number,
        :guardian_no_email_address, :guardian_no_phone_number
      )
      base[:applicant_type] = compute_applicant_type(permitted)
      # Quick-create owns new guardians. Preserve a marker so the final writer can explain an unsaved-guardian refusal.
      base[:unsaved_guardian_present] = submitted_guardian_attributes_present?(permitted)
      base
    end

    def compute_applicant_type(permitted)
      return 'dependent' if inferred_dependent_application_from(permitted)

      raw = permitted[:applicant_type].presence
      # Locked dependent radios are omitted from submission. Unsaved guardian fields imply dependent only when no
      # applicant type is explicit.
      raw = 'dependent' if raw.blank? && submitted_guardian_attributes_present?(permitted)
      raw ||= 'self'

      # The legacy guardian value represents self when guardian and dependent IDs are absent.
      return 'self' if raw == 'guardian' && permitted[:guardian_id].blank? && permitted[:dependent_id].blank?

      raw
    end

    def submitted_guardian_attributes_present?(permitted)
      attributes = permitted[:guardian_attributes]
      attributes.present? && attributes.to_h.values.any?(&:present?)
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
    end

    def add_proof_params_from!(service_params, permitted)
      %w[income residency id].each do |type|
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

      # Medical certification omits the proof suffix used by the other groups.
      service_params[:medical_certification_action] = permitted[:medical_certification_action]
      file_val = permitted[:medical_certification]
      signed_val = permitted[:medical_certification_signed_id]
      service_params[:medical_certification] = file_val if file_val.present?
      service_params[:medical_certification_signed_id] = signed_val if signed_val.present?
      service_params[:medical_certification_rejection_reason] = permitted[:medical_certification_rejection_reason]
      service_params[:medical_certification_custom_rejection_reason] = permitted[:medical_certification_custom_rejection_reason]
    end

    def determine_email_strategy
      return params[:email_strategy] if params[:email_strategy].present?

      if params[:applicant_type] == 'dependent' || inferred_dependent_application?
        use_guardian_email = to_boolean(params[:use_guardian_email])
        return use_guardian_email ? 'guardian' : 'dependent'
      end

      'dependent'
    end

    def determine_phone_strategy
      return params[:phone_strategy] if params[:phone_strategy].present?

      if params[:applicant_type] == 'dependent' || inferred_dependent_application?
        use_guardian_phone = to_boolean(params[:use_guardian_phone])
        return use_guardian_phone ? 'guardian' : 'dependent'
      end

      'dependent'
    end

    def determine_address_strategy
      return params[:address_strategy] if params[:address_strategy].present?

      if params[:applicant_type] == 'dependent' || inferred_dependent_application?
        use_guardian_address = to_boolean(params[:use_guardian_address])
        return use_guardian_address ? 'guardian' : 'dependent'
      end

      'dependent'
    end

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
  end
end
