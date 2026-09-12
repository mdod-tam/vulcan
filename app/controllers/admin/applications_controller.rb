# frozen_string_literal: true

module Admin
  class ApplicationsController < BaseController
    WANTED_ATTACHMENT_NAMES = %w[income_proof residency_proof id_proof medical_certification].freeze

    include ActionView::Helpers::TagHelper
    include ActionView::Helpers::JavaScriptHelper
    include RedirectHelper
    include Admin::ApplicationStatusProcessor
    include TurboStreamResponseHandling
    include ApplicationDataLoading
    include Admin::ProviderInfoRequestLoading
    include RequestMetadataHelper

    before_action :set_application, only: %i[
      show edit update
      request_documents review_proof update_proof_status
      approve reject assign_evaluator assign_trainer request_evaluation
      update_certification_status resend_medical_certification assign_voucher
      upload_medical_certification send_document_signing_request
      queue_medical_certification_form
    ]
    before_action :load_audit_logs_with_service, only: %i[show approve reject]

    def index
      # The default view includes drafts and rejected applications. Archived records require an explicit filter.
      excluded_statuses = %i[archived]
      filtered_status = params[:status]&.to_sym || params[:filter]&.to_sym

      excluded_statuses.delete(filtered_status) if filtered_status && excluded_statuses.include?(filtered_status)

      # Preload attachment existence separately to avoid heavy ActiveStorage eager loading.
      scoped = filtered_scope(build_application_base_scope(exclude_statuses: excluded_statuses))

      scoped = if filtered_status == :training_requests
                 scoped.includes(:user, :training_sessions)
               elsif filtered_status == :evaluation_requests
                 scoped.includes(:user)
               else
                 scoped.includes(:user, :managing_guardian)
               end

      @pagy, page_of_apps = paginate(scoped)
      page_applications = page_of_apps.to_a
      # The array avoids PostgreSQL JSON DISTINCT errors when the relation has joins.
      attachments_index = preload_attachments_for_applications(page_applications)
      @provider_info_request_summaries = provider_info_request_summaries_for(page_applications)

      @applications = decorate_applications_with_storage(page_applications, attachments_index)

      # Preload notifiable for Notification#message and actor for the view.
      @recent_notifications = Notification
                              .includes(:actor, :notifiable)
                              .includes(notifiable: :application)
                              .where('created_at > ?', 7.days.ago)
                              .order(created_at: :desc)
                              .limit(5)
      preload_notification_message_dependencies(@recent_notifications)
    end

    def show
      load_application_show_associations(@application)

      @proof_histories = load_proof_histories(@application)

      certification_service = Applications::CertificationEventsService.new(@application)
      @certification_events = certification_service.certification_events
      @certification_requests = certification_service.request_events
      @max_training_sessions = Policy.max_training_sessions
      @completed_training_sessions_count = @application.completed_training_sessions_count
      @reserved_training_sessions_count = @application.reserved_training_sessions_count
      @remaining_training_sessions = @application.remaining_training_sessions
      load_secure_request_recipient_data(@application)
      load_provider_info_request_data(@application)
      @medical_provider_secure_request_forms = @application.medical_provider_secure_request_forms
                                                           .order(created_at: :desc)
    end

    def edit; end

    def update
      if @application.update(application_params)
        if @application.saved_changes.except('updated_at').any?
          AuditEventService.log(
            action: 'application_updated',
            actor: current_user,
            auditable: @application,
            metadata: {
              admin_id: current_user.id,
              admin_name: current_user.full_name
            }
          )
        end
        # A successful response lets the modal close.
        if params[:modal] == 'true'
          head :ok
        else
          redirect_to admin_application_path(@application), notice: t('.updated')
        end
      else
        render :edit, status: :unprocessable_content
      end
    end

    def search
      @applications = Application.search_by_last_name(params[:q])
    end

    def filter
      @applications = Application.includes(:user, :managing_guardian).where(status: params[:status])
    end

    def batch_approve
      result = Application.batch_update_status(params[:ids], :approved, actor: current_user)
      if result[:success]
        redirect_to admin_applications_path, notice: t('.b_approved')
      else
        render json: { error: 'Unable to approve applications', details: result[:errors] },
               status: :unprocessable_content
      end
    end

    def batch_reject
      result = Application.batch_update_status(params[:ids], :rejected, actor: current_user)
      if result[:success]
        redirect_to admin_applications_path, notice: t('.b_rejected')
      else
        render json: { error: 'Unable to reject applications', details: result[:errors] },
               status: :unprocessable_content
      end
    end

    def request_documents
      @application.request_documents!(user: current_user)
      redirect_to admin_application_path(@application), notice: t('.d_requested')
    end

    def review_proof
      respond_to(&:js)
    end

    def update_proof_status
      admin_user = validate_and_prepare_admin_user

      service = ProofReviewService.new(@application, admin_user, params)
      result = service.call

      if result.success?
        handle_successful_review(result)
      else
        handle_error_response(
          error_message: result.message,
          html_render_action: :show
        )
      end
    end

    # @return [User] The validated admin user
    def validate_and_prepare_admin_user
      Rails.logger.info "Current user: #{current_user.inspect}; Current user type: #{current_user.type}, admin? method result: #{current_user.admin?}"

      if current_user.admin?
        current_user
      elsif ['Administrator', 'Users::Administrator'].include?(current_user.type)
        User.find(current_user.id)
      else
        Rails.logger.error 'Non-admin user attempting to perform admin action'
        current_user
      end
    end

    # Approval can reconcile application or certification status, so it requires a full Turbo redirect.
    def handle_successful_review(result)
      message = "#{params[:proof_type].capitalize} proof #{params[:status]} successfully."
      alert_message = proof_resubmission_delivery_alert(result)
      @application.reload

      if params[:status] == 'approved'
        handle_success_response(
          html_redirect_path: admin_application_path(@application),
          html_message: message,
          turbo_redirect_path: admin_application_path(@application),
          turbo_message: message
        )
      elsif alert_message.present?
        handle_successful_review_with_alert(message, alert_message)
      else
        handle_success_response(
          html_redirect_path: admin_application_path(@application),
          html_message: message,
          turbo_updates: proof_review_turbo_updates
        )
      end
    end

    def handle_successful_review_with_alert(message, alert_message)
      respond_to do |format|
        format.html do
          redirect_to admin_application_path(@application),
                      flash: { notice: message, alert: alert_message }
        end

        format.turbo_stream do
          flash.now[:alert] = alert_message
          handle_turbo_stream_success(message: message, updates: proof_review_turbo_updates)
        end
      end
    end

    def proof_review_turbo_updates
      {
        'attachments-section' => 'attachments',
        'audit-logs' => 'audit_logs',
        'modals' => 'modals'
      }
    end

    def proof_resubmission_delivery_alert(result)
      return unless proof_resubmission_delivery_failed?(result)

      t('admin.proof_reviews.create.resubmission_not_delivered', locale: :en)
    end

    def proof_resubmission_delivery_failed?(result)
      return false unless params[:status].to_s == 'rejected'
      return false unless result.data.is_a?(Hash)

      result.data[:resubmission_delivered] == false
    end

    def approve
      process_application_status_update(:approve)
    end

    def reject
      process_application_status_update(:reject)
    end

    def assign_evaluator
      @application = Application.find(params[:id])
      evaluator = User.find(params[:evaluator_id])

      if @application.assign_evaluator!(evaluator)
        redirect_to admin_application_path(@application),
                    notice: t('.eval_assign_pass')
      else
        redirect_to admin_application_path(@application),
                    alert: @application.errors.full_messages.to_sentence.presence || t('.eval_assign_fail')
      end
    end

    def assign_trainer
      @application = Application.find(params[:id])
      trainer = User.find(params[:trainer_id])

      if @application.assign_trainer!(trainer)
        redirect_to admin_application_path(@application),
                    notice: t('.trainer_assign_pass')
      else
        redirect_to admin_application_path(@application),
                    alert: @application.errors.full_messages.to_sentence.presence || t('.trainer_assign_fail')
      end
    end

    def unassign_trainer
      @application = Application.find(params[:id])

      if @application.unassign_trainer!(actor: current_user, reason: params[:unassign_reason])
        redirect_to admin_application_path(@application),
                    notice: t('.trainer_unassign_pass')
      else
        redirect_to admin_application_path(@application),
                    alert: @application.errors.full_messages.to_sentence.presence || t('.trainer_unassign_fail')
      end
    end

    # This flag adds the application to the evaluation queue. Evaluator assignment removes it.
    def request_evaluation
      @application.request_evaluation!(actor: current_user)
      redirect_to admin_application_path(@application),
                  notice: 'Evaluation requested. Assign an evaluator when ready.'
    rescue ArgumentError => e
      redirect_to admin_application_path(@application), alert: e.message
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_application_path(@application),
                  alert: e.record.errors.full_messages.to_sentence.presence || e.message
    rescue StandardError => e
      Rails.logger.error "Failed to request evaluation for application #{@application.id}: #{e.message}"
      redirect_to admin_application_path(@application),
                  alert: "Failed to request evaluation: #{e.message}"
    end

    def update_certification_status
      status = @application.normalize_certification_status(params[:status])
      update_type = @application.determine_certification_update_type(status, params)

      case update_type
      when :rejection
        process_certification_rejection
      when :status_update
        update_existing_certification_status(status)
      when :new_upload
        upload_new_certification(status)
      else
        handle_error_response(
          error_message: 'Invalid certification update type',
          html_redirect_path: admin_application_path(@application)
        )
      end
    end

    # Accepts modal params (rejection_reason, rejection_reason_code) and
    # upload form params (medical_certification_rejection_reason).
    def process_certification_rejection
      rejection_reason_code = params[:rejection_reason_code].presence
      rejection_reason = params[:medical_certification_rejection_reason].presence ||
                         params[:rejection_reason]

      if rejection_reason.blank? && rejection_reason_code.present?
        rejection_reason = RejectionReason.resolve_text(
          code: rejection_reason_code,
          proof_type: 'medical_certification',
          fallback: nil
        )
      end

      reviewer = Applications::MedicalCertificationReviewer.new(@application, current_user)
      result = reviewer.reject(
        rejection_reason: rejection_reason,
        rejection_reason_code: rejection_reason_code
      )

      if result.success?
        handle_successful_certification_update('Disability certification rejected and provider notified.')
      else
        handle_error_response(
          error_message: "Failed to reject certification: #{result.message}",
          html_redirect_path: admin_application_path(@application)
        )
      end
    end

    # Preserves the existing certification file.
    # @param status [Symbol] The normalized certification status
    def update_existing_certification_status(status)
      result = MedicalCertificationAttachmentService.update_certification_status(
        application: @application,
        status: status,
        admin: current_user,
        submission_method: 'admin_review',
        metadata: { via_ui: true }
      )

      if result[:success]
        handle_successful_status_update(status)
      else
        handle_error_response(
          error_message: "Failed to update certification status: #{result[:error]&.message}",
          html_redirect_path: admin_application_path(@application)
        )
      end
    end

    # @param status [Symbol] The normalized certification status
    def upload_new_certification(status)
      success = @application.update_certification!(
        certification: params[:medical_certification],
        status: status,
        verified_by: current_user,
        rejection_reason: params[:medical_certification_rejection_reason]
      )

      if success
        handle_successful_status_update(status)
      else
        handle_error_response(
          error_message: 'Failed to update certification status.',
          html_redirect_path: admin_application_path(@application)
        )
      end
    end

    def handle_successful_status_update(_status)
      @application.reload
      message = if @application.status_approved?
                  'Disability certification status updated and application auto-approved.'
                else
                  'Disability certification status updated.'
                end
      handle_successful_certification_update(message)
    end

    # Use a full Turbo redirect because certification changes can also auto-approve the application.
    def handle_successful_certification_update(message)
      @application.reload
      handle_success_response(
        html_redirect_path: admin_application_path(@application),
        html_message: message,
        turbo_redirect_path: admin_application_path(@application),
        turbo_message: message
      )
    end

    def resend_medical_certification
      service = Applications::MedicalCertificationService.new(
        application: @application,
        actor: current_user
      )

      result = service.request_certification

      if result.success?
        redirect_to admin_application_path(@application),
                    notice: t('.c_request_pass')
      else
        redirect_to admin_application_path(@application),
                    alert: "Failed to process certification request: #{result.message}"
      end
    end

    def send_document_signing_request
      result = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: current_user,
        service: 'docuseal'
      ).call

      if result.success?
        redirect_to admin_application_path(@application),
                    notice: t('.d_sign_request_pass')
      else
        redirect_to admin_application_path(@application),
                    alert: "Failed to send signing request: #{result.message}"
      end
    end

    def assign_voucher
      if @application.assign_voucher!(assigned_by: current_user)
        redirect_to admin_application_path(@application),
                    notice: t('.v_assign_pass')
      else
        redirect_to admin_application_path(@application),
                    alert: t('.v_assign_fail')
      end
    end

    # Without app/assets/pdfs/medical_certification_form.pdf, generate a PDF with application and provider details.
    def queue_medical_certification_form
      pregenerated_path = Rails.root.join('app/assets/pdfs/medical_certification_form.pdf')
      pdf_source = if File.exist?(pregenerated_path)
                     { type: :pregenerated, source: pregenerated_path }
                   else
                     { type: :generated }
                   end

      result = Applications::MedicalCertificationPdfService.new(
        application: @application,
        actor: current_user,
        pdf_source: pdf_source
      ).call

      respond_to do |format|
        if result.success?
          flash.now[:notice] = "#{t('.queue_print_pass')} #{view_context.link_to('View print queue', admin_print_queue_index_path)}".html_safe
          format.turbo_stream do
            render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash')
          end
          format.html { redirect_to admin_print_queue_index_path, notice: t('.queue_print_pass') }
        else
          flash.now[:alert] = result.message || 'Failed to queue DCF for printing.'
          format.turbo_stream do
            render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash'), status: :unprocessable_content
          end
          format.html { redirect_to admin_application_path(@application), alert: result.message || 'Failed to queue DCF for printing.' }
        end
      end
    end

    # Lazy-loaded B snapshot charts (FY cohort by current status).
    def charts
      service_result = Applications::ReportingService.new.generate_index_chart_data
      @metrics = if service_result.is_a?(BaseService::Result) && service_result.success?
                   service_result.data
                 else
                   empty_index_chart_metrics
                 end

      render partial: 'charts_section', layout: false
    end

    def upload_medical_certification
      status = params[:medical_certification_status]

      if status.blank?
        redirect_to admin_application_path(@application),
                    alert: t('.m_blank')
        return
      end

      if status == 'approved'
        process_accepted_certification
      elsif status == 'rejected'
        if params[:medical_certification_rejection_reason].blank? && params[:rejection_reason_code].blank?
          redirect_to admin_application_path(@application), alert: t('.m_rejection_reason')
          return
        end
        process_certification_rejection
      end
    end

    def process_accepted_certification
      log_certification_params unless Rails.env.production?

      if params[:medical_certification].blank?
        redirect_to admin_application_path(@application),
                    alert: t('.c_file_select')
        return
      end

      result = attach_certification_with_status(:approved)

      result[:status] = 'approved' if result[:success] && result[:status].blank?

      if result[:success] && result[:status] == 'approved'
        flash[:notice] = t('.c_upload_pass')
        redirect_to admin_application_path(@application)
        return
      end

      handle_certification_result(result)
    end

    def extract_submission_method
      params.permit(:submission_method)[:submission_method].presence || 'admin_upload'
    end

    def attach_certification_with_status(status)
      MedicalCertificationAttachmentService.attach_certification(
        application: @application,
        blob_or_file: params[:medical_certification],
        status: status,
        admin: current_user,
        submission_method: extract_submission_method,
        metadata: request_metadata
      )
    end

    def request_metadata
      basic_request_metadata
    end

    def handle_certification_result(result)
      if result[:success]
        status_text = result[:status] || 'processed'
        redirect_to admin_application_path(@application),
                    notice: "Disability certification successfully uploaded and #{status_text}."
      else
        Rails.logger.error "Disability certification operation failed: #{result[:error]&.message}"
        redirect_to admin_application_path(@application),
                    alert: "Failed to process disability certification: #{result[:error]&.message}"
      end
    end

    private

    def prepare_turbo_stream_data
      @application = reload_application_and_associations(@application)
      @proof_histories = load_proof_histories(@application)
      audit_log_builder = Applications::AuditLogBuilder.new(@application)
      @audit_logs = audit_log_builder.build_audit_logs
    end

    def load_notifications
      Notification
        .select('id, recipient_id, actor_id, notifiable_id, notifiable_type, action, read_at, ' \
                'created_at, message_id, delivery_status, metadata')
        .where(notifiable_type: 'Application', notifiable_id: @application.id)
        .where(action: %w[
                 medical_certification_requested medical_certification_received
                 medical_certification_approved medical_certification_rejected
                 review_requested documents_requested proof_approved proof_rejected
               ])
        .order(created_at: :desc)
    end

    def load_application_events
      Event
        .select('id, user_id, action, created_at, metadata')
        .includes(:user)
        .where("action IN (?) AND (metadata->>'application_id' = ? OR metadata @> ?)",
               %w[
                 voucher_assigned voucher_redeemed voucher_expired voucher_cancelled
                 application_created evaluator_assigned trainer_assigned
               ],
               @application.id.to_s,
               { application_id: @application.id }.to_json)
        .order(created_at: :desc)
    end

    def log_param_class
      cls = params[:medical_certification].class.name
      Rails.logger.info "PARAM CLASS: #{cls}"
    end

    def log_upload_type
      file_param = params[:medical_certification]

      upload_type_message =
        if file_param.respond_to?(:content_type)
          "Regular file upload with content_type: #{file_param.content_type}"
        elsif file_param.respond_to?(:[]) && file_param[:signed_id].present?
          'Direct upload with signed_id'
        elsif file_param.is_a?(String)
          'String input (potential direct upload signed ID)'
        else
          "Unknown structure: #{file_param.class.name}"
        end

      Rails.logger.info "Upload type: #{upload_type_message}"
    end

    def log_certification_params
      return unless Rails.env.local?

      Rails.logger.info "DISABILITY CERTIFICATION PARAMS: #{params.to_unsafe_h.inspect}"
      Rails.logger.info "DISABILITY CERTIFICATION FILE PARAM: #{params[:medical_certification].inspect}"

      return if params[:medical_certification].blank?

      log_param_class
      log_upload_type
      Rails.logger.info "REQUEST CONTENT TYPE: #{request.content_type}"
    end

    def load_audit_logs_with_service
      return unless @application

      audit_log_builder = Applications::AuditLogBuilder.new(@application)
      @audit_logs = audit_log_builder.build_deduplicated_audit_logs
    end

    def sort_column
      params[:sort] || 'application_date'
    end

    def sort_direction
      %w[asc desc].include?(params[:direction]) ? params[:direction] : 'desc'
    end

    # Each action loads its additional associations.
    def set_application
      # Preload attachment metadata to avoid N+1 queries without loading variants.
      @application = load_application_with_attachments(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_applications_path, alert: t('.app_not_found')
    end

    def application_params
      permitted = %i[status
                     application_type
                     submission_method
                     medical_provider_name
                     medical_provider_phone
                     medical_provider_fax
                     medical_provider_email
                     alternate_contact_name
                     alternate_contact_phone
                     alternate_contact_email
                     alternate_contact_relationship_type]

      permitted.push(:household_size, :annual_income) if @application.income_proof_required?

      params.expect(application: permitted)
    end

    def require_admin!
      redirect_to root_path, alert: t('shared.unauthorized') unless current_user&.admin?
    end

    def set_current_attributes
      Current.set(request, current_user)
    end

    ### scope / filtering
    def filtered_scope(scope)
      result = Applications::FilterService.new(scope, params).apply_filters
      if result.is_a?(BaseService::Result)
        result.success? ? result.data : scope
      else
        result
      end
    rescue StandardError => e
      Rails.logger.error "Filter error: #{e.message}"
      flash.now[:alert] = t(unfiltered_error)
      scope
    end

    ### pagination
    def paginate(scope)
      pagy(scope, items: 20)
    rescue StandardError => e
      Rails.logger.error "Pagination failed: #{e.message}"
      [Pagy.new(count: scope.count, page: 1), scope.limit(20)]
    end

    def empty_index_chart_metrics
      start_year = current_fiscal_year
      empty_counts = Application.statuses.keys.index_with { 0 }
      {
        current_fy: start_year,
        current_fy_label: FiscalYear.label_for_start_year(start_year),
        current_fy_range_label: '',
        status_chart_data: empty_counts.transform_keys { |k| k.to_s.humanize },
        status_counts: empty_counts
      }
    end
  end
end
