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
      reviewed_blob: @vendor.w9_form.blob,
      admin: @admin,
      status: :approved,
      reviewed_at: Time.current
    )
    assert review.valid?
  end

  test 'valid rejected review' do
    review = W9Review.new(
      vendor: @vendor,
      reviewed_blob: @vendor.w9_form.blob,
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
      reviewed_blob: @vendor.w9_form.blob,
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
      reviewed_blob: @vendor.w9_form.blob,
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
      reviewed_blob: @vendor.w9_form.blob,
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

  test 'reviewed document is immutable' do
    review = create(:w9_review, vendor: @vendor, admin: @admin)
    replacement = ActiveStorage::Blob.create_and_upload!(io: file_fixture('sample_w9.pdf').open,
                                                         filename: 'replacement.pdf', content_type: 'application/pdf')
    assert_raises(ActiveRecord::ReadonlyAttributeError) { review.reviewed_blob_id = replacement.id }
    assert_equal @vendor.w9_form.blob.id, review.reload.reviewed_blob_id
  end

  test 'admin must be an admin type' do
    non_admin = create(:vendor)
    review = W9Review.new(
      vendor: @vendor,
      reviewed_blob: @vendor.w9_form.blob,
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
      reviewed_blob: @vendor.w9_form.blob,
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
      reviewed_blob: @vendor.w9_form.blob,
      admin: @admin,
      reviewed_at: Time.current
    )
    review.status = nil
    assert_not review.valid?
    assert_includes review.errors[:status], "can't be blank"
  end
end
