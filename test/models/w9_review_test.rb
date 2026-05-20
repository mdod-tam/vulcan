# frozen_string_literal: true

require 'test_helper'

class W9ReviewTest < ActiveSupport::TestCase
  setup do
    @vendor = create(:vendor, :with_w9)
    @admin = create(:admin)
  end

  test 'valid approved review' do
    review = W9Review.new(
      vendor: @vendor,
      admin: @admin,
      status: :approved,
      reviewed_at: Time.current
    )
    assert review.valid?
  end

  test 'valid rejected review' do
    review = W9Review.new(
      vendor: @vendor,
      admin: @admin,
      status: :rejected,
      rejection_reason_code: :address_mismatch,
      rejection_reason: "Address doesn't match records",
      reviewed_at: Time.current
    )
    assert review.valid?
  end

  test 'rejected review requires rejection reason' do
    review = W9Review.new(
      vendor: @vendor,
      admin: @admin,
      status: :rejected,
      rejection_reason_code: :address_mismatch,
      rejection_reason: '',
      reviewed_at: Time.current
    )
    assert_not review.valid?
    assert_includes review.errors[:rejection_reason], 'must be provided when rejecting a W9'
  end

  test 'rejected review requires rejection reason code' do
    review = W9Review.new(
      vendor: @vendor,
      admin: @admin,
      status: :rejected,
      rejection_reason: 'Invalid information',
      reviewed_at: Time.current
    )
    assert_not review.valid?
    assert_includes review.errors[:rejection_reason_code], 'must be selected when rejecting a W9'
  end

  test 'approved review clears rejection fields' do
    review = W9Review.new(
      vendor: @vendor,
      admin: @admin,
      status: :approved,
      rejection_reason_code: :address_mismatch,
      rejection_reason: 'Should be cleared',
      reviewed_at: Time.current
    )
    review.valid?
    assert_nil review.rejection_reason
    assert_nil review.rejection_reason_code
  end

  test 'creating approved review updates vendor status' do
    # Use truncation strategy for this test to ensure after_commit callbacks fire
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    # Recreate test data since we cleaned the database
    vendor = create(:vendor, :with_w9)
    admin = create(:admin)

    assert_equal 'pending_review', vendor.w9_status

    W9Review.create!(
      vendor: vendor,
      admin: admin,
      status: :approved,
      reviewed_at: Time.current
    )

    vendor.reload
    assert_equal 'approved', vendor.w9_status
  ensure
    # Restore transaction strategy for other tests
    DatabaseCleaner.strategy = :transaction
  end

  test 'creating rejected review updates vendor status' do
    # Use truncation strategy for this test to ensure after_commit callbacks fire
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    # Recreate test data since we cleaned the database
    vendor = create(:vendor, :with_w9)
    admin = create(:admin)

    assert_equal 'pending_review', vendor.w9_status

    W9Review.create!(
      vendor: vendor,
      admin: admin,
      status: :rejected,
      rejection_reason_code: :address_mismatch,
      rejection_reason: "Address doesn't match records",
      reviewed_at: Time.current
    )

    vendor.reload
    assert_equal 'rejected', vendor.w9_status
  ensure
    # Restore transaction strategy for other tests
    DatabaseCleaner.strategy = :transaction
  end

  test 'rejected review records audit notification without direct mail delivery' do
    review = W9Review.new(
      vendor: @vendor,
      admin: @admin,
      status: :rejected,
      rejection_reason_code: :address_mismatch,
      rejection_reason: "Address doesn't match records",
      reviewed_at: Time.current
    )

    Vendors::RequestW9Resubmission.any_instance.expects(:call).returns(BaseService::Result.new(success: true, message: 'ok', data: {}))
    NotificationService
      .expects(:create_and_deliver!)
      .with(
        has_entries(
          type: 'w9_rejected',
          recipient: @vendor,
          actor: @admin,
          notifiable: @vendor,
          channel: :email,
          audit: true,
          deliver: false,
          metadata: has_entries(
            rejection_reason: "Address doesn't match records",
            rejection_reason_code: 'address_mismatch'
          )
        )
      )

    review.send(:handle_post_review_actions)
  end

  test 'admin must be an admin type' do
    non_admin = create(:vendor)
    review = W9Review.new(
      vendor: @vendor,
      admin: non_admin,
      status: :approved,
      reviewed_at: Time.current
    )
    assert_not review.valid?
    assert_includes review.errors[:admin], 'must be an administrator'
  end

  test 'vendor must be a vendor type' do
    non_vendor = create(:admin)
    review = W9Review.new(
      vendor: non_vendor,
      admin: @admin,
      status: :approved,
      reviewed_at: Time.current
    )
    assert_not review.valid?
    assert_includes review.errors[:vendor], 'must be a vendor'
  end

  test 'reviewed_at is set automatically on create' do
    review = W9Review.new(
      vendor: @vendor,
      admin: @admin,
      status: :approved
    )
    assert_nil review.reviewed_at
    review.valid?
    assert_not_nil review.reviewed_at
  end

  test 'status must be present' do
    review = W9Review.new(
      vendor: @vendor,
      admin: @admin,
      reviewed_at: Time.current
    )
    review.status = nil
    assert_not review.valid?
    assert_includes review.errors[:status], "can't be blank"
  end
end
