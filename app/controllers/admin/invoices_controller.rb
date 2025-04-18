# frozen_string_literal: true

module Admin
  class InvoicesController < Admin::BaseController
    include Pagy::Backend

    before_action :set_invoice, only: %i[show update mark_check_issued mark_check_cashed] # Added :show
    before_action :require_admin!

    def index
      scope = Invoice.includes(:vendor) # Removed :voucher_transactions as it's not used in the index view
                     .order(created_at: :desc)

      scope = apply_filters(scope)
      @pagy, @invoices = pagy(scope, items: 25)

      # Get vendor totals for current period (uninvoiced transactions)
      @vendor_totals = Vendor.active
                             .joins(:voucher_transactions)
                             .where(voucher_transactions: { invoice_id: nil,
                                                            status: VoucherTransaction.statuses[:transaction_completed] })
                             .group('users.id, users.business_name')
                             .select('users.id, users.business_name, SUM(voucher_transactions.amount) as total_amount, COUNT(DISTINCT voucher_transactions.id) as transaction_count')
                             .order('total_amount DESC')

      respond_to do |format|
        format.html
        format.csv do
          send_data generate_csv(@invoices), filename: "invoices-#{Time.current.strftime('%Y%m%d')}.csv",
                                             type: 'text/csv'
        end
      end
    end

    def show
      @transactions = @invoice.voucher_transactions
                              .includes(:voucher)
                              .order(processed_at: :desc)
    end

    def update
      if @invoice.update(invoice_params)
        notice = if @invoice.saved_change_to_status? && @invoice.invoice_approved?
                   'Invoice approved successfully'
                 elsif @invoice.saved_change_to_status? && @invoice.status_invoice_paid?
                   'Payment details recorded successfully'
                 else
                   'Invoice updated successfully'
                 end

        log_event!('Updated invoice details', {
                     status_changed: @invoice.saved_change_to_status?,
                     new_status: @invoice.status,
                     gad_reference: @invoice.gad_invoice_reference
                   })

        redirect_to [:admin, @invoice], notice: notice
      else
        render :show, status: :unprocessable_entity
      end
    end

    def approve
      if @invoice.pending?
        @invoice.update!(status: :approved)
        log_event!('Approved invoice')
        redirect_to [:admin, @invoice], notice: 'Invoice approved successfully'
      else
        redirect_to [:admin, @invoice], alert: 'Invoice must be pending to approve'
      end
    end

    private

    def set_invoice
      @invoice = Invoice.find(params[:id])
    end

    def invoice_params
      params.require(:invoice).permit(
        :status,
        :payment_notes,
        :gad_invoice_reference
      )
    end

    def apply_filters(scope)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(vendor_id: params[:vendor_id]) if params[:vendor_id].present?

      if params[:date_range].present?
        case params[:date_range]
        when 'today'
          scope = scope.where(created_at: Time.current.beginning_of_day..Time.current.end_of_day)
        when 'week'
          scope = scope.where(created_at: 1.week.ago.beginning_of_day..Time.current.end_of_day)
        when 'month'
          scope = scope.where(created_at: 1.month.ago.beginning_of_day..Time.current.end_of_day)
        when 'custom'
          if params[:start_date].present? && params[:end_date].present?
            start_date = Date.parse(params[:start_date])
            end_date = Date.parse(params[:end_date])
            scope = scope.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
          end
        end
      end

      if params[:payment_status].present?
        case params[:payment_status]
        when 'pending_check'
          scope = scope.where(status: :approved, check_number: nil)
        when 'check_issued'
          scope = scope.where.not(check_number: nil).where(check_cashed_at: nil)
        when 'check_cashed'
          scope = scope.where.not(check_cashed_at: nil)
        end
      end

      scope
    end

    def generate_csv(invoices)
      require 'smarter_csv'
      require 'tempfile'
      require 'fileutils' # Although Tempfile handles cleanup, good practice if more complex ops needed

      invoices_data = invoices.map do |invoice|
        {
          'Invoice Number' => invoice.invoice_number,
          'Vendor' => invoice.vendor.business_name,
          'Total Amount' => invoice.total_amount,
          'Status' => invoice.status,
          'Created At' => invoice.created_at.strftime('%Y-%m-%d %H:%M:%S'),
          'Check Number' => invoice.check_number,
          'Check Issued At' => invoice.check_issued_at&.strftime('%Y-%m-%d'),
          'Check Cashed At' => invoice.check_cashed_at&.strftime('%Y-%m-%d'),
          'GAD Reference' => invoice.gad_invoice_reference
        }
      end

      # Return empty string if no data to prevent errors
      return '' if invoices_data.empty?

      temp_file = nil
      csv_content = nil

      begin
        # Create a temporary file
        temp_file = Tempfile.new(['invoices', '.csv'])

        # Use SmarterCSV::Writer with the temp file path
        # Pass the whole data array; smarter_csv handles headers automatically
        writer = SmarterCSV::Writer.new(temp_file.path)
        writer << invoices_data
        writer.finalize # This saves and closes the file stream managed by smarter_csv

        # Rewind and read the content from the temp file
        temp_file.rewind
        csv_content = temp_file.read
      ensure
        # Ensure the temp file is closed and deleted
        temp_file&.close
        temp_file&.unlink # Deletes the file from the filesystem
      end

      csv_content
    end

    def log_event!(action, metadata = {})
      @invoice.events.create!(
        user: current_user,
        action: action,
        metadata: metadata.merge(
          changes: @invoice.saved_changes,
          admin_id: current_user.id
        )
      )
    end
  end
end
