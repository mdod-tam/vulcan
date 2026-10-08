# frozen_string_literal: true

module VendorPortal
  class DashboardController < VendorPortal::BaseController
    # Authenticate_vendor! is inherited from BaseController, but let's be explicit for clarity
    before_action :authenticate_vendor!

    def show
      @recent_transactions = current_user.latest_transactions
                                         .includes(:voucher, voucher_transaction_products: :product)
      @not_yet_invoiced_total = current_user.pending_transaction_total
      @awaiting_payment_total = current_user.awaiting_payment_total
      @on_hold_count = current_user.voucher_transactions.pending_invoice.on_billing_hold.count
      @monthly_totals = current_user.total_transactions_by_period(6.months.ago, Time.current)
      @needs_w9 = !current_user.w9_form.attached?
      @pending_approval = current_user.vendor_pending?

      # For the chart data
      @monthly_totals_chart = @monthly_totals.transform_keys do |date|
        date.strftime('%B %Y')
      end
    end
  end
end
