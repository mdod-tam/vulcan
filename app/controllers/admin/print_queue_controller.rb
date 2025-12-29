# frozen_string_literal: true

require 'rubygems'
require 'zip'

module Admin
  class PrintQueueController < Admin::BaseController
    before_action :require_admin

    def index
      @pending_letters = PrintQueueItem.pending.includes(:constituent, :application).order(created_at: :desc)
      @printed_letters = PrintQueueItem.printed.includes(:constituent, :application,
                                                         :admin).order(printed_at: :desc).limit(50)
    end

    def show
      @letter = PrintQueueItem.find(params[:id])

      respond_to do |format|
        format.html
        format.pdf do
          if @letter.pdf_letter.attached?
            begin
              send_data @letter.pdf_letter.download,
                        filename: "#{@letter.letter_type}_#{@letter.constituent.id}.pdf",
                        type: 'application/pdf',
                        disposition: 'inline'
            rescue ActiveStorage::FileNotFoundError => e
              Rails.logger.error "[STORAGE_ERROR] PDF file missing for PrintQueueItem ##{@letter.id}: #{e.message}"
              redirect_to admin_print_queue_index_path, alert: t('.pdf_file_missing_storage')
            end
          else
            redirect_to admin_print_queue_index_path, alert: t('.pdf_not_available')
          end
        end
      end
    end

    def mark_as_printed
      letter = PrintQueueItem.find(params[:id])
      letter.update(status: :printed, printed_at: Time.current, admin: current_user)
      redirect_to admin_print_queue_index_path, notice: t('.letter_marked_printed')
    end

    def mark_batch_as_printed
      @letters = PrintQueueItem.where(id: params[:letter_ids])
                               .includes(:constituent)

      if @letters.empty?
        # Set the correct flash notice for an empty batch as expected by the test
        redirect_to admin_print_queue_index_path, notice: t('admin.print_queue.mark_as_printed.letter_marked_empty')
        return
      end

      # Update all selected letters to printed status
      @letters.update_all(
        status: PrintQueueItem.statuses[:printed],
        printed_at: Time.current,
        admin_id: current_user.id
      )

      redirect_to admin_print_queue_index_path,
                  notice: "#{@letters.count} #{'letter'.pluralize(@letters.count)} marked as printed"
    end

    def download_batch
      @letters = PrintQueueItem.where(id: params[:letter_ids])
                               .includes(:constituent, :pdf_letter_attachment)

      return redirect_empty_letters if @letters.empty?
      return send_single_letter(@letters.first) if @letters.one?

      send_multiple_letters(@letters)
    end

    private

    def require_admin
      return if current_user&.admin?

      redirect_to root_path, alert: t('alerts.unauthorized_page')
    end

    def redirect_empty_letters
      redirect_to admin_print_queue_index_path, alert: t('admin.print_queue.redirect_empty_letters.no_selected_letters')
    end

    def send_single_letter(letter)
      filename = letter_filename(letter)
      send_data letter.pdf_letter.download,
                filename: filename,
                type: 'application/pdf',
                disposition: 'attachment',
                stream: true
    end

    def send_multiple_letters(letters)
      zipfile_name = "letters_batch_#{Time.zone.today.strftime('%Y%m%d')}.zip"

      # Create a zip file in memory
      zip_data = create_zip_data(letters)

      # Send the data directly, avoiding file system operations
      send_data zip_data,
                filename: zipfile_name,
                type: 'application/zip',
                disposition: 'attachment'
    rescue StandardError => e
      handle_zip_error(e)
    end

    # Create zip file directly in memory
    def create_zip_data(letters)
      # Create a StringIO to hold the zip data
      buffer = StringIO.new

      Zip::OutputStream.write_buffer(buffer) do |zos|
        letters.each do |letter_item|
          next unless letter_item.pdf_letter.attached?

          # Add each PDF to the zip file
          filename = letter_filename(letter_item)
          zos.put_next_entry(filename)
          zos.write letter_item.pdf_letter.download
        end
      end

      # Return the binary data
      buffer.string
    end

    def handle_zip_error(exception)
      Rails.logger.error("PDF batch download error: #{exception.message}")
      redirect_to admin_print_queue_index_path, alert: t(download_error)
    end

    def letter_filename(letter)
      "#{letter.letter_type}_#{letter.constituent.id}.pdf"
    end
  end
end
