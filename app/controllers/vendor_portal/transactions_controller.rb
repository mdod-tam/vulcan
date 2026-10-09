# frozen_string_literal: true

module VendorPortal
  # Controller for managing vendor transactions
  class TransactionsController < BaseController
    include Pagy::Backend
    include PurchasePage

    # How a vendor may say a purchase reaches the customer. Unspecified is only the starting state.
    FULFILLMENT_MODES = %w[shipping local_pickup].freeze

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
      return '' if transactions.empty?

      require 'smarter_csv'
      require 'tempfile'

      transactions_data = transactions.map { |t| transaction_to_hash(t).transform_values { |value| SpreadsheetCell.safe(value) } }

      Tempfile.create(['vendor-transactions', '.csv']) do |temp_file|
        writer = SmarterCSV::Writer.new(temp_file.path)
        writer << transactions_data
        writer.finalize
        temp_file.read
      end
    end

    def billing_label(transaction)
      return helpers.invoice_status_label(transaction.invoice) if transaction.invoice

      transaction.on_billing_hold? ? 'On hold' : 'Not yet invoiced'
    end

    def transaction_to_hash(transaction)
      {
        'Date' => transaction.processed_at.strftime('%Y-%m-%d %H:%M'),
        'Voucher Code' => transaction.voucher&.code,
        'Amount' => transaction.amount,
        'Status' => transaction.status.humanize,
        'Reference Number' => transaction.reference_number,
        'Constituent Name' => transaction.voucher&.application&.user&.full_name,
        'Invoice Number' => transaction.invoice&.invoice_number,
        'Billing' => billing_label(transaction)
      }
    end
  end
end
