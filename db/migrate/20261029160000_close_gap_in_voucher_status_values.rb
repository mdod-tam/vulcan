# frozen_string_literal: true

# Voucher statuses skipped 1 (active 0, redeemed 2, expired 3, cancelled 4). They are now numbered 0 through 3.
# Per the pre-1.0 baseline the model keeps no mapping for the old numbers: this renumbers the stored values once.
class CloseGapInVoucherStatusValues < ActiveRecord::Migration[8.0]
  def up
    execute 'UPDATE vouchers SET status = status - 1 WHERE status >= 2'
  end

  def down
    execute 'UPDATE vouchers SET status = status + 1 WHERE status >= 1'
  end
end
