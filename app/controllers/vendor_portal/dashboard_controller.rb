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
      now = Time.current.in_time_zone(Rails.application.config.time_zone)
      @months = 6.times.map { |index| now.to_date.beginning_of_month - index.months }.reverse
      @monthly_totals = current_user.total_transactions_by_period(@months.first.in_time_zone(now.time_zone), now)
      @highest_month, @highest_month_total = @monthly_totals.max_by { |_month, total| total }

      # For the chart data
      @monthly_totals_chart = @monthly_totals.transform_keys do |date|
        date.strftime('%B %Y')
      end
    end
  end
end
