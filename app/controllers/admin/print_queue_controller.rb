# frozen_string_literal: true

module Admin
  class PrintQueueController < Admin::BaseController
    before_action :load_letter, only: %i[cancel replace_request]
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

      send_export(Letters::Delivery.export!(selected_ids, actor: current_user))
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
      redirect_to admin_print_queue_index_path, notice: 'Selected letters marked as printed.'
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
      @pending_letters = PrintQueueItem.unreleased.includes(:constituent, :application).order(created_at: :desc)
      @released_letters = PrintQueueItem.awaiting_print_confirmation.includes(:constituent, :application).order(released_at: :desc)
      @printed_letters = PrintQueueItem.printed.includes(:constituent, :application, :admin).order(printed_at: :desc).limit(50)
      @canceled_letters = PrintQueueItem.canceled.includes(:constituent, :application).order(canceled_at: :desc, id: :desc).limit(50)
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
      render_release_error(message)
    end

    def render_release_error(message)
      detail = params[:id].present?
      if detail
        load_detail
      else
        load_queue
        preserve_exportable_selection if action_name == 'download_batch'
      end
      respond_to do |format|
        format.html do
          flash.now[:alert] = message
          render(detail ? :show : :index, status: :unprocessable_content)
        end
        format.turbo_stream do
          target = detail ? 'print-letter-content' : 'print-queue-content'
          partial = detail ? 'admin/print_queue/detail' : 'admin/print_queue/queue'
          render turbo_stream: turbo_stream.replace(target, partial: partial, locals: { error: message }),
                 status: :unprocessable_content
        end
      end
    end

    def preserve_exportable_selection
      items = PrintQueueItem.pending.where(id: @selected_letter_ids).includes(:constituent, :application, :secure_request_form, :pdf_letter_attachment)
      @selected_letter_ids = items.filter_map { |item| item.id.to_s if item.pdf_letter.attached? && item.delivery_decision.allowed? }
    end

    def show_export_failure(error)
      AuditEventService.log(action: 'letter_export_failed', actor: current_user,
                            metadata: { print_queue_item_ids: selected_ids.presence || [params[:id]], error_class: error.class.name })
      render_release_error('Couldn’t prepare the PDF. Nothing was released. Try again.')
    end
  end
end
