# frozen_string_literal: true

module Admin
  class PrintQueueController < Admin::BaseController
    rescue_from Letters::Delivery::ReleaseDenied, with: :show_release_refusal
    rescue_from ActiveStorage::FileNotFoundError, Zip::Error, IOError, with: :show_export_failure

    def index
      load_queue
    end

    def show
      @letter = PrintQueueItem.includes(:constituent, :application, :admin).find(params[:id])
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

    def mark_batch_as_printed
      Letters::Delivery.mark_printed!(selected_ids, actor: current_user)
      redirect_to admin_print_queue_index_path, notice: 'Selected letters marked as printed.'
    end

    private

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
      flash.now[:alert] = "Nothing was released. #{error.message}"
      load_queue
      render :index, status: :unprocessable_content
    end

    def show_export_failure(error)
      AuditEventService.log(action: 'letter_export_failed', actor: current_user,
                            metadata: { print_queue_item_ids: selected_ids.presence || [params[:id]], error_class: error.class.name })
      flash.now[:alert] = 'The PDF could not be prepared. Nothing was released. Review the selected letters and try again.'
      load_queue
      render :index, status: :unprocessable_content
    end
  end
end
