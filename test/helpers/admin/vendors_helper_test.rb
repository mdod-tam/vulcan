# frozen_string_literal: true

require 'test_helper'

module Admin
  class VendorsHelperTest < ActionView::TestCase
    test 'historical approved and rejected decisions explicitly identify the unknown document' do
      approved = W9Review.new(status: :approved)
      rejected = W9Review.new(status: :rejected, rejection_reason_code: :address_mismatch, rejection_reason: 'Send a corrected address.')

      approved_item = VendorsHelper::W9HistoryItem.new(:review, approved, Time.current)
      rejected_item = VendorsHelper::W9HistoryItem.new(:review, rejected, Time.current)

      assert_equal 'Reviewed document unknown.', vendor_w9_history_item_detail(approved_item)
      assert_equal 'Reviewed document unknown. Address Mismatch: Send a corrected address.', vendor_w9_history_item_detail(rejected_item)
    end

    test 'a known document does not acquire the historical unknown label' do
      review = W9Review.new(status: :rejected, reviewed_blob_id: 123, rejection_reason_code: :other, rejection_reason: 'Use the current form.')
      item = VendorsHelper::W9HistoryItem.new(:review, review, Time.current)

      assert_equal 'Other: Use the current form.', vendor_w9_history_item_detail(item)
    end
  end
end
