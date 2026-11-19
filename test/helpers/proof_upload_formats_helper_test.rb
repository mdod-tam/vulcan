# frozen_string_literal: true

require 'test_helper'

class ProofUploadFormatsHelperTest < ActionView::TestCase
  include ProofUploadFormatsHelper

  test 'financial scan recovery separates owner types and reviewed versions' do
    stubs(:controller_path).returns('admin/icanconnect/financial_records')
    order = PurchaseOrder.new(id: 17, lock_version: 2)
    training = TrainingSession.new(id: 17, lock_version: 2)
    context = document_scan_context(order)
    assert_equal 'admin/icanconnect/financial_records:PurchaseOrder:17:2', context
    assert_equal 'admin/icanconnect/financial_records:TrainingSession:17:2', document_scan_context(training)
    assert_not_equal context, document_scan_context(training)
    order.lock_version = 3
    assert_not_equal context, document_scan_context(order)
  end
end
