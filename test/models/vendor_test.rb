# frozen_string_literal: true

require 'test_helper'

class VendorTest < ActiveSupport::TestCase
  test 'valid vendor can be created with factory' do
    vendor = create(:vendor, :approved, :with_w9) # Use :with_w9 trait to attach a W9, which sets it to in_progress

    assert vendor.valid?
    assert_equal 'Users::Vendor', vendor.type
    assert vendor.vendor_approved?

    # Use update_column to bypass callbacks that might reset w9_status
    vendor.update_column(:w9_status, :approved) # Ensure W9 status is approved for can_process_vouchers?
    assert vendor.can_process_vouchers?
  end

  test 'monthly transaction totals use Eastern processed dates and Date keys' do
    travel_to Time.zone.local(2026, 10, 9, 12) do
      vendor = create(:vendor)
      create(:voucher_transaction, vendor: vendor, amount: 25, processed_at: Time.utc(2026, 10, 1, 3, 59, 59))
      create(:voucher_transaction, vendor: vendor, amount: 50, processed_at: Time.utc(2026, 10, 1, 4))
      create(:voucher_transaction, :failed, vendor: vendor, amount: 100, processed_at: Time.utc(2026, 10, 1, 4))
      create(:voucher_transaction, amount: 200, processed_at: Time.utc(2026, 10, 1, 4))

      totals = vendor.total_transactions_by_period(Time.zone.local(2026, 9, 1), Time.current)

      assert_equal({ Date.new(2026, 9, 1) => 25.to_d, Date.new(2026, 10, 1) => 50.to_d }, totals)
    end
  end
end
