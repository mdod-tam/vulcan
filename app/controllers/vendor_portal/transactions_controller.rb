# frozen_string_literal: true

module VendorPortal
  # Controller for managing vendor transactions
  class TransactionsController < BaseController
    include Pagy::Backend
    include PurchasePage

    # How a vendor may say a purchase reaches the customer. Unspecified is only the starting state.
    FULFILLMENT_MODES = %w[shipping local_pickup].freeze
    CSV_HEADERS = ['Date', 'Voucher Code', 'Amount', 'Status', 'Reference Number', 'Constituent Name', 'Invoice Number', 'Billing'].freeze

    def index
      filter = VoucherTransactions::ListFilter.new(vendor: current_user, params: params)
      transactions_scope = filter.call
      @filter_errors = filter.errors
      @total_amount = transactions_scope.sum(:amount)
      @transaction_count = transactions_scope.count

      respond_to do |format|
        format.html do
          @pagy, @transactions = pagy(transactions_scope, limit: 20)
          render :index, status: @filter_errors.any? ? :unprocessable_content : :ok
        end
        format.csv do
          if @filter_errors.any?
            render plain: @filter_errors.join("\n"), status: :unprocessable_content
            next
          end

          send_data generate_csv(transactions_scope),
                    filename: "vendor-transactions-#{Time.current.strftime('%Y%m%d')}.csv",
                    type: 'text/csv'
        end
      end
    end

    def show
      load_purchase(params[:id])
      render_purchase_page
    end

    # Changes only how the purchase reaches the customer; see VoucherTransactions::FulfillmentService.
    def update
      load_purchase(params[:id])
      mode = params.require(:fulfillment_mode)
      return redirect_to_purchase(alert: 'Choose shipping or local pickup.') unless FULFILLMENT_MODES.include?(mode)

      fulfillment_service.change_mode!(mode: mode, expected_version: params.require(:fulfillment_version))
      redirect_to_purchase(notice: 'Fulfillment updated.')
    rescue VoucherTransactions::FulfillmentService::StaleError
      redirect_to_purchase(alert: STALE_MESSAGE)
    rescue VoucherTransactions::FulfillmentService::NotFulfillableError
      redirect_to_purchase(alert: NOT_FULFILLABLE_MESSAGE)
    end

    private

    def generate_csv(transactions)
      headers = transactions.empty? ? [] : CSV_HEADERS
      CsvExport.generate(headers: headers, actor: current_user, export_type: 'vendor_transactions') do |csv|
        transactions.each { |transaction| csv << transaction_csv_row(transaction) }
      end
    end

    def billing_label(transaction)
      return helpers.invoice_status_label(transaction.invoice) if transaction.invoice

      transaction.on_billing_hold? ? 'On hold' : 'Not yet invoiced'
    end

    def transaction_csv_row(transaction)
      [transaction.processed_at.strftime('%Y-%m-%d %H:%M'), transaction.voucher&.code, transaction.amount,
       transaction.status.humanize, transaction.reference_number, transaction.voucher&.application&.user&.full_name,
       transaction.invoice&.invoice_number, billing_label(transaction)]
    end
  end
end
