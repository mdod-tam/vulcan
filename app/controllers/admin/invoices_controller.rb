# frozen_string_literal: true

module Admin
  class InvoicesController < Admin::BaseController
    include Pagy::Backend

    before_action :set_invoice, only: %i[show update approve]
    before_action :require_admin!

    def index
      scope = Invoice.includes(:vendor)
                     .order(created_at: :desc)

      scope = apply_filters(scope)
      @pagy, @invoices = pagy(scope, items: 25)

      # Get vendor totals for current period (uninvoiced transactions)
      @vendor_totals = Vendor.active
                             .joins(:voucher_transactions)
                             .where(voucher_transactions: { invoice_id: nil,
                                                            status: VoucherTransaction.statuses[:transaction_completed] })
                             .group('users.id, users.business_name')
                             .select('users.id, users.business_name, ' \
                                     'SUM(voucher_transactions.amount) as total_amount, ' \
                                     'COUNT(DISTINCT voucher_transactions.id) as transaction_count')
                             .order(total_amount: :desc)

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
      handle_missing_gad_reference and return if missing_gad_reference?

      if @invoice.update(invoice_params)
        log_event!('Updated invoice details', {
                     status_changed: @invoice.saved_change_to_status?,
                     new_status: @invoice.status,
                     gad_reference: @invoice.gad_invoice_reference
                   })
        redirect_to [:admin, @invoice], notice: invoice_update_notice
      else
        render_update_error
      end
    end

    def approve
      if @invoice.status_invoice_pending?
        @invoice.update!(status: :invoice_approved)
        log_event!('Approved invoice')
        redirect_to [:admin, @invoice], notice: t(invoice_approved_pass)
      else
        redirect_to [:admin, @invoice], alert: t(invoice_approved_pending)
      end
    end

    private

    def set_invoice
      @invoice = Invoice.find(params[:id])
    end

    def invoice_params
      params.expect(
        invoice: %i[status
                    payment_notes
                    gad_invoice_reference]
      )
    end

    # Helpers for update action refactoring
    def missing_gad_reference?
      invoice_params[:status] == 'invoice_paid' && params.dig(:invoice, :gad_invoice_reference).blank?
    end

    def handle_missing_gad_reference
      flash[:alert] = t(gad_blank)
      set_transactions
      render :show, status: :unprocessable_content
    end

    def render_update_error
      set_transactions
      render :show, status: :unprocessable_content
    end

    def invoice_update_notice
      if @invoice.saved_change_to_status? && @invoice.status_invoice_approved?
        'Invoice approved successfully'
      elsif @invoice.saved_change_to_status? && @invoice.status_invoice_paid?
        'Payment details recorded successfully'
      else
        'Invoice updated successfully'
      end
    end

    def set_transactions
      @transactions = @invoice.voucher_transactions
                              .includes(:voucher)
                              .order(processed_at: :desc)
    end

    def apply_filters(scope)
      scope = apply_basic_filters(scope)
      scope = apply_date_range_filter(scope)
      apply_payment_status_filter(scope)
    end

    def apply_basic_filters(scope)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(vendor_id: params[:vendor_id]) if params[:vendor_id].present?
      scope
    end

    def apply_date_range_filter(scope)
      return scope if params[:date_range].blank?

      case params[:date_range]
      when 'today'
        scope.where(created_at: Time.current.all_day)
      when 'week'
        scope.where(created_at: 1.week.ago.beginning_of_day..Time.current.end_of_day)
      when 'month'
        scope.where(created_at: 1.month.ago.beginning_of_day..Time.current.end_of_day)
      when 'custom'
        apply_custom_date_range_filter(scope)
      else
        scope
      end
    end

    def apply_custom_date_range_filter(scope)
      return scope unless params[:start_date].present? && params[:end_date].present?

      start_date = Date.parse(params[:start_date])
      end_date = Date.parse(params[:end_date])
      scope.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
    end

    def apply_payment_status_filter(scope)
      return scope if params[:payment_status].blank?

      case params[:payment_status]
      when 'pending_check'
        scope.where(status: :approved, check_number: nil)
      when 'check_issued'
        scope.where.not(check_number: nil).where(check_cashed_at: nil)
      when 'check_cashed'
        scope.where.not(check_cashed_at: nil)
      else
        scope
      end
    end

    def generate_csv(invoices)
      require 'smarter_csv'
      require 'tempfile'
      require 'fileutils'

      invoices_data = format_invoices_for_csv(invoices)
      return '' if invoices_data.empty?

      generate_csv_content(invoices_data)
    end

    def format_invoices_for_csv(invoices)
      invoices.map do |invoice|
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
    end

    def generate_csv_content(invoices_data)
      temp_file = nil
      csv_content = nil

      begin
        temp_file = create_temp_csv_file(invoices_data)
        csv_content = read_csv_content(temp_file)
      ensure
        cleanup_temp_file(temp_file)
      end

      csv_content
    end

    def create_temp_csv_file(invoices_data)
      temp_file = Tempfile.new(['invoices', '.csv'])
      writer = SmarterCSV::Writer.new(temp_file.path)
      writer << invoices_data
      writer.finalize
      temp_file
    end

    def read_csv_content(temp_file)
      temp_file.rewind
      temp_file.read
    end

    def cleanup_temp_file(temp_file)
      temp_file&.close
      temp_file&.unlink
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
