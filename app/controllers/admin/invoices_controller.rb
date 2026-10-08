# frozen_string_literal: true

module Admin
  # Invoice list, detail, and the staff steps after generation. Every change goes through
  # Invoices::Workflow; generation ("Invoice now", retry) goes through Invoices::GenerationService.
  class InvoicesController < Admin::BaseController
    include Pagy::Backend

    before_action :require_admin!
    before_action :set_invoice, only: %i[show approve record_payment withdraw correction_note]

    CSV_COLUMNS = {
      'Invoice Number' => :invoice_number,
      'Vendor' => ->(invoice) { invoice.vendor.business_name },
      'Period Start' => ->(invoice) { invoice.start_date.to_date.iso8601 },
      'Covered Through' => ->(invoice) { invoice.covered_through.iso8601 },
      'Total Amount' => ->(invoice) { format('%.2f', invoice.total_amount) },
      'Status' => ->(invoice) { helpers.invoice_status_label(invoice) },
      'Approved At' => ->(invoice) { invoice.approved_at&.to_date&.iso8601 },
      'Payment Date' => ->(invoice) { invoice.payment_date&.to_date&.iso8601 },
      'Payment Method' => ->(invoice) { helpers.invoice_payment_method_label(invoice) },
      'Payment Reference' => :payment_reference,
      'Check Number' => :check_number,
      'GAD Reference' => :gad_invoice_reference,
      'Recorded By' => ->(invoice) { invoice.paid_by&.full_name }
    }.freeze

    def index
      @filter = Invoices::ListFilter.new(params)
      scope = @filter.call
      flash.now[:alert] = @filter.errors.to_sentence if @filter.errors.any?

      respond_to do |format|
        format.html do
          @pagy, @invoices = pagy(scope, limit: 25)
          load_billing_overview
        end
        format.csv do
          send_data invoices_csv(scope), filename: "invoices-#{Time.current.strftime('%Y%m%d')}.csv", type: 'text/csv'
        end
      end
    end

    def show
      load_show_data
    end

    def approve
      workflow.approve!(expected_status: params[:expected_status])
      redirect_to [:admin, @invoice], notice: 'Invoice approved.'
    rescue Invoices::Workflow::Refused => e
      redirect_to [:admin, @invoice], alert: e.message
    end

    def record_payment
      workflow.record_payment!(expected_status: params[:expected_status], **payment_params.to_h.symbolize_keys)
      redirect_to [:admin, @invoice], notice: 'Payment recorded.'
    rescue Invoices::Workflow::Refused => e
      redirect_to [:admin, @invoice], alert: e.message
    rescue ActiveRecord::RecordInvalid => e
      @payment_errors = e.record.errors
      @payment_input = payment_params
      load_show_data
      flash.now[:alert] = 'The payment was not recorded.'
      render :show, status: :unprocessable_content
    end

    def withdraw
      workflow.withdraw!(expected_status: params[:expected_status], reason: params[:reason])
      redirect_to [:admin, @invoice], notice: 'Invoice withdrawn. Its purchases are released and can be added to a later invoice.'
    rescue Invoices::Workflow::Refused => e
      redirect_to [:admin, @invoice], alert: e.message
    end

    def correction_note
      workflow.add_correction_note!(reference: params[:reference], note: params[:note])
      redirect_to [:admin, @invoice], notice: 'Correction note added.'
    rescue Invoices::Workflow::Refused => e
      redirect_to [:admin, @invoice], alert: e.message
    end

    def generate
      vendor = Users::Vendor.find(params.expect(:vendor_id))
      result = Invoices::GenerationService.new(vendor_ids: [vendor.id]).call
      redirect_to admin_invoices_path, **generation_flash(result, vendor)
    end

    private

    def set_invoice
      @invoice = Invoice.find(params.expect(:id))
    end

    def workflow
      Invoices::Workflow.new(@invoice, actor: current_user)
    end

    def payment_params
      params.expect(payment: %i[payment_date payment_method payment_reference check_number gad_invoice_reference payment_notes])
    end

    def load_show_data
      EmailDelivery::Visibility.preload([@invoice])
      @transactions = @invoice.voucher_transactions.includes(:voucher).order(processed_at: :desc)
      @audit_events = @invoice.events.includes(:user).order(created_at: :desc)
    end

    # Purchases not yet on an invoice, by vendor (suspended vendors included), and vendors whose last
    # automatic invoicing failed.
    def load_billing_overview
      @not_yet_invoiced = VoucherTransaction.pending_invoice.joins(:vendor)
                                            .group('users.id', 'users.business_name')
                                            .order('users.business_name')
                                            .pluck('users.id', 'users.business_name',
                                                   Arel.sql('SUM(CASE WHEN voucher_transactions.billing_hold_at IS NULL THEN voucher_transactions.amount ELSE 0 END)'),
                                                   Arel.sql('COUNT(*) FILTER (WHERE voucher_transactions.billing_hold_at IS NULL)'),
                                                   Arel.sql('COUNT(*) FILTER (WHERE voucher_transactions.billing_hold_at IS NOT NULL)'))
      @generation_failures = InvoiceGenerationFailure.unresolved.includes(:vendor).order(:attempted_at)
    end

    def generation_flash(result, vendor)
      return { alert: "Invoicing for #{vendor.business_name} failed. Try again later." } unless result.success?
      return { alert: 'Invoicing is already running. Try again in a few minutes.' } if result.data[:already_running]
      return { alert: "Invoicing for #{vendor.business_name} failed again. It stays on the retry list." } if result.data[:vendors_failed].to_i.positive?
      return { notice: "#{vendor.business_name} has no purchases before today to invoice." } if result.data[:invoices_created].zero?

      { notice: "Invoice created for #{vendor.business_name}." }
    end

    def invoices_csv(scope)
      CSV.generate do |csv|
        csv << CSV_COLUMNS.keys
        scope.each do |invoice| # Same order as the page.
          csv << CSV_COLUMNS.values.map { |value| value.is_a?(Symbol) ? invoice.public_send(value) : instance_exec(invoice, &value) }
        end
      end
    end
  end
end
