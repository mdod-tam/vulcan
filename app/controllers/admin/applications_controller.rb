# frozen_string_literal: true

module Admin
  class ApplicationsController < BaseController
    include RedirectHelper
    include TurboStreamResponseHandling
    include ApplicationDataLoading
    include Admin::ProviderInfoRequestLoading
    include RequestMetadataHelper

    before_action :set_application, only: %i[
      show edit update
      review_proof update_proof_status
      update_certification_status upload_disability_certification
    ]

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
      @delivery_attention = EmailDelivery::Visibility.application_attention(page_applications)
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
      prepare_application_show
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

    def review_proof
      respond_to(&:js)
    end

    def update_proof_status
      # Admin::BaseController#require_admin! has already refused any user who is not an administrator.
      result = ProofReviewService.new(@application, current_user, params).call

      if result.success?
        handle_successful_review(result)
      elsif result.data&.dig(:commit_state) == :unknown
        redirect_to admin_application_path(@application), alert: result.message, status: :see_other
      else
        prepare_application_show if request.format.html?
        handle_error_response(
          error_message: result.message,
          html_render_action: :show
        )
      end
    end

    def update_certification_status
      status = @application.normalize_certification_status(params[:status])
      # This status action does not accept a new certification file.
      if @application.rejection_requested?(status, params)
        process_certification_rejection
      else
        update_existing_certification_status(status)
      end
    end

    # Charts show the fiscal-year cohort by current status.
    def charts
      service_result = Applications::ReportingService.new.generate_index_chart_data
      @metrics = if service_result.is_a?(BaseService::Result) && service_result.success?
                   service_result.data
                 else
                   empty_index_chart_metrics
                 end

      render partial: 'charts_section', layout: false
    end

    def upload_disability_certification
      status = params[:disability_certification_status]

      if status.blank?
        redirect_to admin_application_path(@application),
                    alert: t('.m_blank')
        return
      end

      if status == 'approved'
        process_accepted_certification
      elsif status == 'rejected'
        if params[:disability_certification_rejection_reason].blank? && params[:rejection_reason_code].blank?
          redirect_to admin_application_path(@application), alert: t('.m_rejection_reason')
          return
        end
        process_certification_rejection
      end
    end

    private

    # Approval can reconcile application or certification status, so it requires a full Turbo redirect.
    def handle_successful_review(result)
      message = "#{params[:proof_type].capitalize} proof #{params[:status]} successfully."
      alert_message = [result.data&.dig(:warning), proof_resubmission_delivery_alert(result)].compact_blank.join(' ')
      @application.reload

      if params[:status] == 'approved'
        return handle_successful_review_with_alert(message, alert_message, redirect: true) if alert_message.present?

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

    def handle_successful_review_with_alert(message, alert_message, redirect: false)
      respond_to do |format|
        format.html do
          redirect_to admin_application_path(@application),
                      flash: { notice: message, alert: alert_message }
        end

        format.turbo_stream do
          if redirect
            redirect_to admin_application_path(@application),
                        flash: { notice: message, alert: alert_message }, status: :see_other
          else
            flash.now[:alert] = alert_message
            handle_turbo_stream_success(message: message, updates: proof_review_turbo_updates)
          end
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
      return t('admin.proof_reviews.create.resubmission_suppressed', locale: :en) if result.data[:resubmission_suppressed]

      t('admin.proof_reviews.create.resubmission_not_delivered', locale: :en)
    end

    def proof_resubmission_delivery_failed?(result)
      return false unless params[:status].to_s == 'rejected'
      return false unless result.data.is_a?(Hash)

      result.data[:resubmission_delivered] == false
    end

    # Accepts modal params (rejection_reason, rejection_reason_code) and
    # upload form params (disability_certification_rejection_reason).
    def process_certification_rejection
      rejection_reason_code = params[:rejection_reason_code].presence
      rejection_reason = params[:disability_certification_rejection_reason].presence ||
                         params[:rejection_reason]

      if rejection_reason.blank? && rejection_reason_code.present?
        rejection_reason = RejectionReason.resolve_text(
          code: rejection_reason_code,
          proof_type: 'disability_certification',
          fallback: nil,
          application: @application
        )
      end

      reviewer = Applications::DisabilityCertificationReviewer.new(@application, current_user)
      result = reviewer.reject(
        rejection_reason: rejection_reason,
        rejection_reason_code: rejection_reason_code
      )

      if result.success?
        handle_successful_certification_update(result.message)
      elsif result.data&.dig(:commit_state) == :unknown
        redirect_to admin_application_path(@application), alert: result.message, status: :see_other
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
      result = DisabilityCertificationAttachmentService.update_certification_status(
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

    def process_accepted_certification
      if params[:disability_certification].blank?
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
    rescue UploadedDocument::Refused => e
      redirect_to admin_application_path(@application), alert: e.user_message_for('Disability certification')
    rescue DisabilityCertificationAttachmentService::StaffUploadNotAllowed
      redirect_to admin_application_path(@application), alert: t('.m_not_allowed')
    end

    def extract_submission_method
      params.permit(:submission_method)[:submission_method].presence || 'admin_upload'
    end

    def attach_certification_with_status(status)
      DisabilityCertificationAttachmentService.attach_certification(
        application: @application,
        blob_or_file: params[:disability_certification],
        status: status,
        admin: current_user,
        submission_method: extract_submission_method,
        metadata: basic_request_metadata
      )
    end

    def handle_certification_result(result)
      if result[:success]
        status_text = result[:status] || 'processed'
        redirect_to admin_application_path(@application),
                    notice: "Disability certification successfully uploaded and #{status_text}."
      else
        Rails.logger.error "Disability certification operation failed: #{result[:error]&.class&.name}"
        redirect_to admin_application_path(@application),
                    alert: "Failed to process disability certification: #{result[:error]&.message}"
      end
    end

    def prepare_application_show
      load_application_show_associations(@application)
      load_audit_logs_with_service
      Application.preload_equipment_fulfillment([@application])
      @return_context = Equipment::RequestParameters.return_context(params)
      @equipment_items = @application.equipment_items.sort_by(&:id)
      ActiveRecord::Associations::Preloader.new(records: @equipment_items, associations: { events: :user }).call
      @equipment_audit_records = Equipment::AuditRecords.for(@audit_logs + @equipment_items.flat_map { |item| item.events.to_a })
      load_attachment_data

      certification_service = Applications::CertificationEventsService.new(@application)
      @certification_events = certification_service.certification_events
      @certification_requests = certification_service.request_events
      @training_history = @application.training_sessions.includes(:trainer, :product_trained_on).order(:created_at, :id)
      @max_training_sessions = Policy.max_training_sessions
      @completed_training_sessions_count = @application.completed_training_sessions_count
      @reserved_training_sessions_count = @application.reserved_training_sessions_count
      @remaining_training_sessions = @application.remaining_training_sessions
      load_provider_info_request_data(@application)
      load_certification_delivery_data
    end

    def load_attachment_data
      @application.proof_reviews.load
      load_secure_request_recipient_data(@application)
    end

    def prepare_turbo_stream_data
      @application = reload_application_and_associations(@application)
      load_certification_delivery_data
      load_attachment_data
      audit_log_builder = Applications::AuditLogBuilder.new(@application)
      @audit_logs = audit_log_builder.build_audit_logs
      @secure_request_delivery_owners_by_id = audit_log_builder.delivery_owners_by_id
      @equipment_audit_records = Equipment::AuditRecords.for(@audit_logs)
    end

    def load_audit_logs_with_service
      return unless @application

      audit_log_builder = Applications::AuditLogBuilder.new(@application)
      @audit_logs = audit_log_builder.build_deduplicated_audit_logs
      @secure_request_delivery_owners_by_id = audit_log_builder.delivery_owners_by_id
    end

    # Each action loads its additional associations.
    def set_application
      # The loader queries attachment metadata without variants or updates to association caches.
      @application = load_application_with_attachments(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_applications_path, alert: t('alerts.app_not_found')
    end

    # Status is not editable here: it changes only through workflow actions, which go through
    # Application#transition_status! and record history and audit events.
    def application_params
      permitted = %i[application_type
                     submission_method
                     certifying_professional_name
                     certifying_professional_phone
                     certifying_professional_fax
                     certifying_professional_email
                     alternate_contact_name
                     alternate_contact_phone
                     alternate_contact_email
                     alternate_contact_relationship_type]

      permitted.push(:household_size, :annual_income) if @application.income_proof_required?

      params.expect(application: permitted)
    end

    def filtered_scope(scope)
      result = Applications::FilterService.new(scope, params).apply_filters
      if result.is_a?(BaseService::Result)
        result.success? ? result.data : scope
      else
        result
      end
    rescue StandardError => e
      Rails.logger.error "Filter error: #{e.class.name}"
      flash.now[:alert] = t('alerts.unfiltered_error')
      scope
    end

    def paginate(scope)
      pagy(scope, items: 20)
    rescue StandardError => e
      Rails.logger.error "Pagination failed: #{e.class.name}"
      [Pagy.new(count: scope.count, page: 1), scope.limit(20)]
    end

    def empty_index_chart_metrics
      start_year = FiscalYear.current_start_year
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
