# frozen_string_literal: true

module Admin
  class PrintQueueController < Admin::BaseController
    before_action :load_letter, only: %i[cancel replace_request discard_printed_copy]
    rescue_from Letters::Delivery::ReleaseDenied, with: :show_release_refusal
    rescue_from ActiveStorage::FileNotFoundError, Zip::Error, IOError, with: :show_export_failure

    def index
      load_queue
    end

    def show
      load_detail
      # Old embeds and bookmarks cannot initiate a release through GET.
      redirect_to admin_print_queue_path(@letter), status: :see_other if request.format.pdf?
    end

    def release
      send_export(Letters::Delivery.export!([params[:id]], actor: current_user))
    end

    def download_batch
      return redirect_to admin_print_queue_index_path, status: :see_other unless request.post?

      export = Letters::Delivery.export!(selected_ids, actor: current_user)
      response.headers['Content-Location'] = batch_admin_print_queue_index_path(ids: selected_ids.join(','))
      send_export(export)
    end

    def batch
      load_batch
      @selected_letter_ids = @batch_letters.map { |letter| letter.id.to_s } - params[:skipped].to_s.split(',')
    end

    def mark_in_outgoing_mail
      Letters::Delivery.mark_in_outgoing_mail!(selected_ids, actor: current_user)
      redirect_to batch_return_path, status: :see_other, notice: 'Marked in outgoing mail.'
    end

    def discard_printed_copy
      Letters::Delivery.discard_printed_copy!(@letter, actor: current_user)
      redirect_to admin_print_queue_path(@letter), status: :see_other, notice: 'Copy marked as discarded.'
    end

    def dismiss_preparation_failure
      notice = Notification.letter_preparation_attention.error_delivery_status.find(params.expect(:notification_id))
      notice.update_metadata!(:letter_preparation_resolved_at, Time.current.iso8601)
      redirect_to admin_print_queue_index_path, status: :see_other, notice: 'Preparation follow-up closed.'
    end

    def close_follow_up
      letter = PrintQueueItem.follow_up_needed.find(params.expect(:id))
      Letters::Delivery.close_follow_up!(letter, actor: current_user)
      redirect_to admin_print_queue_index_path, status: :see_other, notice: 'Letter follow-up closed.'
    end

    def mark_as_printed
      Letters::Delivery.mark_printed!([params[:id]], actor: current_user)
      redirect_to admin_print_queue_index_path, notice: 'Letter marked as printed.'
    end

    def cancel
      if Letters::Delivery.cancel!(@letter, reason: 'operator_canceled', actor: current_user)
        redirect_to admin_print_queue_path(@letter), status: :see_other, notice: 'Letter canceled.'
      else
        redirect_to admin_print_queue_path(@letter), status: :see_other, alert: 'Only a pending letter can be canceled.'
      end
    end

    def replace_request
      return redirect_to(admin_print_queue_path(@letter), status: :see_other, alert: 'This paper request can’t be replaced.') unless replaceable_paper_request?

      result = replace_paper_request(@letter.secure_request_form)
      feedback = result.success? ? { notice: 'Replacement letter queued.' } : { alert: replacement_failure_message(result) }
      redirect_to admin_print_queue_path(@letter), status: :see_other, **feedback
    end

    def mark_batch_as_printed
      Letters::Delivery.mark_printed!(selected_ids, actor: current_user)
      redirect_to batch_return_path, status: :see_other, notice: 'Selected letters marked as printed.'
    end

    private

    def replacement_failure_message(result)
      return result.message if result.data&.dig(:commit_state) == :unknown

      @letter.reload
      return result.message unless @letter.pdf_letter.attached? && @letter.delivery_decision.allowed?

      "#{result.message} The previous letter is still available."
    end

    def load_letter
      @letter = PrintQueueItem.includes(:constituent, :application, :secure_request_form, :pdf_letter_attachment).find(params.expect(:id))
    end

    def load_detail
      load_letter
      @letter_decision = @letter.delivery_decision
      @letter_exportable = @letter_decision.allowed? && @letter.pdf_letter.attached?
      @letter_replaceable = replaceable_paper_request?
      @mail_refusals = mail_refusals([@letter])
    end

    def replaceable_paper_request?
      form = @letter.secure_request_form
      form && @letter.application_id == form.application_id && !@letter.canceled? && form.postal_delivery_eligible?(application: @letter.application)
    end

    def replace_paper_request(form)
      options = { application: @letter.application, actor: current_user, resend_of: form }
      if form.kind_provider_info_request?
        Applications::RequestProviderInfo.new(**options).call
      else
        proof_type = SecureRequestForm::PROOF_TYPES_BY_KIND.fetch(form.kind)
        Applications::RequestProofResubmission.new(**options, proof_type: proof_type).call
      end
    end

    def load_queue
      @selected_letter_ids = selected_ids
      pending = PrintQueueItem.unreleased.includes(:constituent, :application, :secure_request_form, :pdf_letter_attachment).order(:created_at, :id)
      @pending_letters, blocked = PrintQueueItem.cache { pending.partition { |letter| ready_to_download?(letter) } }
      @released_letters = PrintQueueItem.awaiting_print_confirmation.includes(:constituent, :application, :secure_request_form).order(:released_at, :id)
      @mail_letters = PrintQueueItem.awaiting_mail_handoff.includes(:constituent, :application, :secure_request_form, :admin).order(:printed_at, :id)
      @mail_refusals = mail_refusals(@released_letters.to_a + @mail_letters.to_a)
      completed_prints = PrintQueueItem.printed.where.not(id: PrintQueueItem.awaiting_mail_handoff)
      @printed_letters = completed_prints.includes(:constituent, :secure_request_form, :admin, :mail_handoff_by).order(printed_at: :desc).limit(50)
      @canceled_letters = PrintQueueItem.canceled.includes(:constituent, :secure_request_form).order(canceled_at: :desc, id: :desc).limit(50)
      @attention_letters = blocked + PrintQueueItem.follow_up_needed.order(:canceled_at, :id).to_a
      @preparation_notices = Notification.letter_preparation_attention.includes(:notifiable).order(:created_at, :id)
    end

    def load_batch
      @batch_letters = PrintQueueItem.where(id: batch_ids.split(',')).where.not(released_at: nil)
                                     .includes(:constituent, :application, :secure_request_form, :admin, :mail_handoff_by).order(:id).to_a
      @mail_refusals = mail_refusals(@batch_letters)
    end

    def mail_refusals(letters)
      PrintQueueItem.cache do
        letters.filter_map do |letter|
          next unless letter.outgoing_letter? && letter.released_at? && (letter.pending? || letter.awaiting_mail_handoff? || letter.canceled?)

          reason = Letters::Delivery.mail_handoff_refusal(letter)
          [letter.id, reason] if reason
        end.to_h
      end
    end

    def batch_ids
      params[:ids].to_s
    end

    def batch_return_path
      return admin_print_queue_index_path if batch_ids.blank?

      skipped = batch_ids.split(',') - selected_ids
      batch_admin_print_queue_index_path({ ids: batch_ids, skipped: skipped.join(',').presence }.compact)
    end

    def selected_ids
      Array(params[:letter_ids]).map(&:to_s).uniq
    end

    def send_export(export)
      response.headers['Cache-Control'] = 'no-store, private'
      send_data export.bytes, filename: export.filename, type: export.content_type, disposition: 'attachment'
    end

    def show_release_refusal(error)
      message = action_name.in?(%w[release download_batch]) ? "Nothing was released. #{error.message}" : error.message
      @release_refusals = error.reasons if action_name == 'download_batch'
      render_release_error(message)
    end

    def render_release_error(message)
      detail = params[:id].present?
      if detail
        load_detail
      elsif batch_ids.present?
        load_batch
        @selected_letter_ids = selected_ids
      else
        load_queue
      end
      preserve_exportable_selection if action_name == 'download_batch'
      page = if detail
               :show
             elsif batch_ids.present?
               :batch
             else
               :index
             end
      respond_to do |format|
        format.html do
          flash.now[:alert] = message
          render page, status: :unprocessable_content
        end
        format.turbo_stream do
          target = detail ? 'print-letter-content' : 'print-queue-content'
          partial = { show: 'detail', batch: 'batch', index: 'queue' }.fetch(page)
          render turbo_stream: turbo_stream.replace(target, partial: "admin/print_queue/#{partial}", locals: { error: message }),
                 status: :unprocessable_content
        end
      end
    end

    def preserve_exportable_selection
      items = PrintQueueItem.pending.where(id: @selected_letter_ids).includes(:constituent, :application, :secure_request_form, :pdf_letter_attachment)
      @selected_letter_ids = items.filter_map { |item| item.id.to_s if ready_to_download?(item) }
    end

    def ready_to_download?(letter)
      !@release_refusals&.key?(letter.id) && letter.pdf_letter.attached? && letter.delivery_decision.allowed?
    end

    def show_export_failure(error)
      AuditEventService.log(action: 'letter_export_failed', actor: current_user,
                            metadata: { print_queue_item_ids: selected_ids.presence || [params[:id]], error_class: error.class.name })
      render_release_error('Couldn’t prepare the PDF. Nothing was released. Try again.')
    end
  end
end
