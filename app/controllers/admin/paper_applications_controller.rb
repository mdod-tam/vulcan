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

    # Only the ten facts detection scores. Everything else the form holds -- application answers,
    # proof files, provider details -- is irrelevant here and must not be uploaded to a check.
    IDENTITY_REVIEW_FIELDS = %i[
      first_name last_name date_of_birth email phone
      physical_address_1 physical_address_2 city state zip_code
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

    # Every proof input a re-rendered form has to put back. The controller owns this allowlist
    # because it is the same kind of decision as the rest of `build_submitted_params` -- what may be
    # echoed back to staff -- and not something a view should be deciding for itself.
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

    # Read-only identity check the admin form runs before it submits.
    #
    # POST keeps the applicant's facts out of the URL; keeping them out of the *logs* is the
    # parameter filtering in config/initializers/filter_parameter_logging.rb, which covers the
    # names, contact, date of birth, address and the decision token.
    #
    # Every submission calls this, including the ordinary case where nothing matches: the browser
    # cannot know which outcome applies until it asks, and submitting first would mean discovering a
    # soft match or contact conflict only through a server-rendered failure -- which discards the
    # four selected proof files, since these are native file inputs with no direct upload.
    #
    # So the form sends *only* identity facts here, never the files. A `clear` answer submits
    # natively straight afterwards; the other answers put a decision in front of staff while the
    # completed form, and its file selections, stay untouched in the DOM.
    #
    # Nothing here writes, and the answer is advisory: PaperApplicationService recomputes the same
    # review at the write boundary and that recomputation decides.
    def identity_review
      review = Applications::PaperIdentityReview.new(
        constituent_params: identity_review_facts,
        admin: current_user,
        contact_flag_params: identity_review_flags
      ).call

      response.headers['Cache-Control'] = 'no-store'
      render json: identity_review_payload(review)
    end

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
      @applicant_type = params[:applicant_type].presence || (@show_create_guardian_form ? 'dependent' : 'self')
      @restored_from_submission = false
      @selected_guardian = nil
      @selected_dependent = nil
    end

    def create
      log_file_and_form_params
      service_params = paper_application_processing_params # Use the new method

      service = Applications::PaperApplicationService.new(
        params: service_params,
        admin: current_user,
        quick_created_portal_user_ids: quick_created_portal_user_ids
      )

      service_result = service.create

      if service_result
        clear_quick_created_portal_user_markers!
        success_message = generate_success_message(service.application)
        # Every warning the write produced, not just reconciliation: a post-commit callback can fail
        # for reasons that have nothing to do with workflow state, and the admin still needs telling.
        if service.warning_message.present?
          handle_reconciliation_warning_response(
            application: service.application,
            success_message: success_message,
            warning_message: service.warning_message,
            commit_confirmed: service.commit_confirmed?
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

        # The service result owns the transaction outcome, so a false result always re-renders the
        # form with the real error.
        #
        # This used to branch on `service.application&.persisted?` first, meaning to catch
        # "committed but reconciliation failed" -- a state the service does not produce, because a
        # reconciliation problem returns true with a warning, and a post-commit callback failure now
        # does too -- the service checks durable existence before deciding, so a committed
        # application is never reported as a failure. Inferring commit state here from
        # `service.application&.persisted?` was wrong in both directions: false after a rollback
        # restores the record, true after a commit whose callback then raised. The invariants that
        # keep this branch honest are pinned in paper_application_service_test.rb.
        handle_service_failure(service)
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

    def handle_reconciliation_warning_response(application:, success_message:, warning_message:, commit_confirmed: true)
      # An unconfirmed write must not be routed to its own detail page: if the row is not there, the
      # show action's "application not found" replaces the very guidance telling staff to check
      # before entering it again. The list is somewhere they can act on either way.
      target = commit_confirmed ? admin_application_path(application) : admin_applications_path
      notice = commit_confirmed ? success_message : nil

      respond_to do |format|
        format.html do
          redirect_to target, flash: { notice: notice, alert: warning_message }
        end

        format.turbo_stream do
          redirect_to target,
                      status: :see_other,
                      flash: { notice: notice, alert: warning_message }
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

    # A record, not the raw params hash. The guardian form is a `fields_for` bound to this value, so
    # every field on it calls a reader -- `first_name`, `state`, and the rest -- and a hash answers
    # none of them. Handing over the hash raised NoMethodError and took the whole re-render down, so
    # the inline-guardian branch could never be retried at all.
    def rebuilt_guardian_attributes(submitted_params)
      submitted = submitted_params[:guardian_attributes]
      return Users::Constituent.new if submitted.blank?

      Users::Constituent.new.tap { |guardian| guardian.assign_attributes(submitted) }
    end

    def rebuilt_constituent(service, existing_application, submitted_params)
      constituent = service.constituent || existing_application&.user || Constituent.new
      # Re-render the form with the submitted values, even for persisted records.
      constituent.assign_attributes(submitted_params[:constituent]) if submitted_params[:constituent].present?
      # The disability booleans post under `applicant_attributes` but are columns on the user, and
      # the form binds that group to this object. Without them a failed create returns a form with
      # every disability checkbox cleared. Sliced to the user's own columns because the group also
      # carries self_certify_disability, which belongs to Application and is rendered from there.
      constituent.assign_attributes(user_owned_disability_attributes(submitted_params))
      constituent
    end

    def rebuilt_application(service, existing_application, submitted_params)
      application = service.application || existing_application || Application.new
      application.assign_attributes(submitted_params[:application]) if submitted_params[:application].present?
      # `self_certify_disability` posts under `applicant_attributes` alongside the disability
      # booleans, but it is a column on Application, so it never arrives in
      # `submitted_params[:application]`. Reading it off `service.application` alone worked only when
      # the failure happened *after* the application was built; a failure before that -- constituent
      # processing today, an identity refusal under A2 -- left the required checkbox cleared.
      certification = submitted_self_certification(submitted_params)
      application.self_certify_disability = certification unless certification.nil?
      application
    end

    # Which branch of the form staff were on. Without this a dependent submission comes back as a
    # blank adult form: the applicant-type radios, the guardian creation form, and the dependent
    # fields are all keyed off it, so losing it discards the whole identity selection.
    def restore_applicant_branch_state(submitted_params)
      # The applicant-type radios are disabled once a branch is locked in, so a resubmission from the
      # retry form omits the parameter entirely. Falling back to 'self' there would silently move a
      # dependent application onto the adult branch on its second failure. The writer already infers
      # the branch from the guardian selection; the re-render uses the same rule.
      @applicant_type = submitted_params[:applicant_type].presence ||
                        (inferred_dependent_application_from(submitted_params) ? 'dependent' : 'self')
      @show_create_guardian_form = submitted_params[:show_create_guardian_form].present? ||
                                   creating_guardian_inline?(submitted_params)
      # The picker refetches the selected adult on connect; tell it the fields already hold newer,
      # submitted values so it does not paste the on-file record back over them.
      @restored_from_submission = true
      # The guardian picker shows its selected pane on connect but only fills the identity box when
      # staff click a search result, so a retry rendered "a guardian is selected" without saying
      # which one. Looked up here so the re-render can name them.
      @selected_guardian = User.find_by(id: submitted_params[:guardian_id])
      # A preserved dependent_id means the next POST will reuse and update that record. Rendering it
      # as "New Dependent Information" tells staff the opposite of what the form is about to do.
      @selected_dependent = User.find_by(id: submitted_params[:dependent_id])
    end

    def creating_guardian_inline?(submitted_params)
      @applicant_type == 'dependent' &&
        submitted_params[:guardian_attributes].present? &&
        submitted_params[:guardian_id].blank?
    end

    # nil when the field was not submitted at all, so a fresh form is left untouched rather than
    # being told the applicant did not self-certify.
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
        :existing_constituent_id, :identity_decision, :contact_info_mode, :contact_info_verified,
        :no_email_address, :no_phone_number,
        :guardian_no_email_address, :guardian_no_phone_number,
        :email_strategy, :phone_strategy, :address_strategy,
        :use_guardian_email, :use_guardian_phone, :use_guardian_address,
        # Proof workflow inputs are instructions rather than attributes of any record, so nothing
        # else carries them back into a re-rendered form. All three parts are needed together: the
        # action alone restores "Reject" while losing the reason that made it meaningful.
        *PROOF_WORKFLOW_FIELDS,
        # These two switch whole sections off. Losing them on a retry does not merely blank a field:
        # the JavaScript re-imposes the provider and income requirements they were suppressing, so an
        # otherwise unchanged retry becomes unsubmittable.
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

    # Main method to construct parameters for the PaperApplicationService
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

      # A selected existing dependent submits no identity fields at all -- those are on-file facts,
      # not paper-intake input -- so the presence of a name cannot be the only signal. `dependent_id`
      # is the more direct one and is checked first.
      permitted[:dependent_id].present? || permitted.dig(:constituent, :first_name).present?
    end

    def permitted_paper_params
      params.permit(
        :relationship_type, :guardian_id, :dependent_id, :applicant_type, :existing_constituent_id,
        :identity_decision, :contact_info_mode, :contact_info_verified,
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

    def identity_review_facts
      params.expect(constituent: IDENTITY_REVIEW_FIELDS)
    end

    # The no-contact flags live outside the constituent hash but change the facts before detection,
    # so the check has to see them or it would review a different applicant than the writer verifies.
    def identity_review_flags
      params.permit(:no_email_address, :no_phone_number)
    end

    # Built field by field rather than serializing the review result. The result carries
    # `identity_facts` and whole candidate records; rendering it wholesale would ship far more PII to
    # the browser than a decision needs -- and would quietly grow whenever the result gains a field.
    # The candidate rows are rendered exactly as the review presented them, never rebuilt here. The
    # decision token is signed over that snapshot, so a second serializer on this side would be a
    # second definition of "what staff were shown" and could drift out of agreement with the one the
    # write boundary verifies against.
    def identity_review_payload(review)
      payload = { state: review.state, reasons: review.reasons, candidates: review.presented_candidates }
      if review.token.present?
        payload[:token] = review.token
        payload[:expires_at] = Applications::PaperIdentityDecision.expires_at(review.token)&.iso8601
      end
      payload
    end

    def base_params_from(permitted)
      base = permitted.slice(
        :relationship_type, :guardian_id, :dependent_id, :no_medical_provider_information,
        :existing_constituent_id, :identity_decision, :contact_info_mode, :contact_info_verified,
        :no_email_address, :no_phone_number,
        :guardian_no_email_address, :guardian_no_phone_number
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

    # NOTE: cast_boolean_params and cast_boolean_for are provided by the ParamCasting concern
    # The complex parameter casting is handled by cast_complex_boolean_params
  end
end
