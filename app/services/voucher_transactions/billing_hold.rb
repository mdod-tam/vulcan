# frozen_string_literal: true

module VoucherTransactions
  # Keeps a purchase off every invoice until staff release it, for example while a suspected error or
  # fraud is looked into. Only a purchase not on an invoice can be held: withdraw its invoice first.
  # Holding does not change the constituent's voucher balance.
  class BillingHold
    class Refused < StandardError; end

    def initialize(purchase, actor:)
      @purchase = purchase
      @actor = actor
    end

    def hold!(reason:)
      reason = reason.to_s.strip
      raise Refused, 'Give a reason for holding this voucher redemption.' if reason.blank?

      change('voucher_transaction_billing_hold_placed', reason: reason) do |purchase|
        raise Refused, 'This voucher redemption is already on hold.' if purchase.on_billing_hold?
        raise Refused, 'This voucher redemption is on an invoice. Withdraw the invoice before holding it.' if purchase.invoice_id

        purchase.update!(billing_hold_at: Time.current, billing_hold_by: @actor, billing_hold_reason: reason)
      end
    end

    def release!
      change('voucher_transaction_billing_hold_released') do |purchase|
        raise Refused, 'This voucher redemption is not on hold.' unless purchase.on_billing_hold?

        purchase.update!(billing_hold_at: nil, billing_hold_by: nil, billing_hold_reason: nil)
      end
    end

    private

    def change(action, **metadata)
      VoucherTransaction.transaction do
        purchase = VoucherTransaction.lock.find(@purchase.id)
        yield purchase
        AuditEventService.log(action: action, actor: @actor, auditable: purchase.voucher,
                              metadata: metadata.merge(voucher_id: purchase.voucher_id, transaction_id: purchase.id,
                                                       operation_id: SecureRandom.uuid))
        purchase
      end
    end
  end
end
