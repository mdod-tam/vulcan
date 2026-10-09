# frozen_string_literal: true

module Admin
  # Holds a purchase off every invoice, or releases it. See VoucherTransactions::BillingHold.
  class BillingHoldsController < Admin::BaseController
    before_action :require_admin!
    before_action { @purchase = VoucherTransaction.find(params.expect(:voucher_transaction_id)) }

    def create
      hold.hold!(reason: params[:reason])
      redirect_to admin_voucher_path(@purchase.voucher), notice: "Voucher redemption #{@purchase.reference_number} is on hold and will not be invoiced until released."
    rescue VoucherTransactions::BillingHold::Refused => e
      redirect_to admin_voucher_path(@purchase.voucher), alert: e.message
    end

    def destroy
      hold.release!
      redirect_to admin_voucher_path(@purchase.voucher), notice: "Voucher redemption #{@purchase.reference_number} is released and will be on the next invoice."
    rescue VoucherTransactions::BillingHold::Refused => e
      redirect_to admin_voucher_path(@purchase.voucher), alert: e.message
    end

    private

    def hold
      VoucherTransactions::BillingHold.new(@purchase, actor: current_user)
    end
  end
end
