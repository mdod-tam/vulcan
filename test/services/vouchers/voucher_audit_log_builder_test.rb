# frozen_string_literal: true

require 'test_helper'

module Vouchers
  class VoucherAuditLogBuilderTest < ActiveSupport::TestCase
    test 'deduplicated logs return the voucher\'s events instead of failing quietly' do
      voucher = create(:voucher, :active)
      AuditEventService.log(action: 'voucher_updated', actor: create(:admin), auditable: voucher,
                            metadata: { voucher_id: voucher.id, changes: { 'notes' => [nil, 'Checked'] } })

      builder = VoucherAuditLogBuilder.new(voucher)

      assert_includes builder.build_deduplicated_audit_logs.map(&:action), 'voucher_updated'
      assert_empty builder.errors
    end
  end
end
