# frozen_string_literal: true

require 'test_helper'

module Vendors
  class ReviewW9Test < ActiveSupport::TestCase
    setup do
      @vendor = create(:vendor, :with_w9)
      @admin = create(:admin)
      @blob = @vendor.w9_form.blob
    end

    test 'a decision records its document status and audit atomically' do
      result = decide

      assert_predicate result, :success?
      assert_equal @blob.id, result.data[:review].reload.reviewed_blob_id
      assert_predicate @vendor.reload, :w9_status_approved?
      assert_equal [@blob.id], @vendor.w9_archive.blobs.pluck(:id)
      event = Event.find_by!(auditable: @vendor, action: 'w9_approved')
      assert_equal @blob.id, event.metadata['reviewed_blob_id']
      assert_predicate @vendor, :vendor_pending?
    end

    test 'approval of A cannot approve replacement B' do
      ReplaceW9.call(vendor: @vendor, file: upload)
      replacement = @vendor.reload.w9_form.blob
      assert_not_equal @blob.id, replacement.id

      assert_no_changes -> { [W9Review.count, Event.count] } do
        assert_predicate decide, :failure?
      end
      assert_predicate @vendor.reload, :w9_status_pending_review?
      assert_equal replacement.id, @vendor.w9_form.blob.id
    end

    test 'repeated decisions make no changes' do
      assert_predicate decide(status: 'rejected'), :success?
      count = @vendor.reload.w9_rejections_count

      assert_no_changes -> { [W9Review.count, Event.count, Notification.count] } do
        assert_predicate decide, :failure?
      end
      assert_predicate @vendor.reload, :w9_status_rejected?
      assert_equal count, @vendor.w9_rejections_count
    end

    test 'no decision and an invalid decision are refused without writes' do
      [nil, '', 'something_else'].each do |status|
        assert_no_changes -> { [W9Review.count, Event.count] } do
          result = decide(status: status)
          assert_predicate result, :failure?
          assert_equal @blob.id, result.data[:review].reviewed_blob_id
          assert_includes result.data[:review].errors[:status], 'must be explicitly approved or rejected'
        end
      end
      assert_predicate @vendor.reload, :w9_status_pending_review?
    end

    test 'audit failure rolls back review status archive and rejection count' do
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))

      assert_no_changes -> { [W9Review.count, ActiveStorage::Attachment.where(record: @vendor, name: 'w9_archive').count] } do
        assert_predicate decide(status: 'rejected'), :failure?
      end
      assert_predicate @vendor.reload, :w9_status_pending_review?
      assert_equal 0, @vendor.w9_rejections_count
    end

    test 'reviewed files survive replacement and purge jobs' do
      decide
      ReplaceW9.call(vendor: @vendor, file: upload)
      ActiveStorage::PurgeJob.perform_now(@blob)
      CleanupUnattachedUploadsJob.perform_now

      assert ActiveStorage::Blob.exists?(@blob.id)
      assert @blob.service.exist?(@blob.key)
      assert_equal @blob.id, @vendor.w9_reviews.last.reviewed_blob_id
      assert @vendor.w9_archive.blobs.exists?(@blob.id)
    end

    test 'unique vendor document constraint rejects a second review' do
      decide
      duplicate = W9Review.new(vendor: @vendor, admin: @admin, reviewed_blob: @blob, status: :rejected,
                               rejection_reason_code: :other, rejection_reason: 'Duplicate')
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
    end

    test 'a later upload does not receive an obsolete rejection request' do
      review = decide(status: 'rejected').data[:review]
      ReplaceW9.call(vendor: @vendor, file: upload)

      assert_no_difference -> { VendorSecureRequestForm.count } do
        result = RequestW9Resubmission.new(vendor: @vendor, actor: @admin, review: review).call
        assert_predicate result, :failure?
      end
    end

    test 'retrying a reviewed current reference preserves its rejection and history without a replacement' do
      @vendor.update!(w9_status: :rejected, w9_rejections_count: 1)
      review = create(:w9_review, :rejected, vendor: @vendor, admin: @admin, reviewed_blob: @blob)
      @blob.with_lock { W9Document.protect!(@blob, vendor: @vendor) }
      reference = W9Document.reference(@blob, vendor: @vendor)
      snapshot = lambda do
        @vendor.reload
        [@vendor.w9_form.blob.id, @vendor.w9_archive.blobs.ids.sort, @vendor.w9_status,
         @vendor.w9_rejections_count, @vendor.w9_reviews.count, Event.where(auditable: @vendor).count]
      end

      assert_no_changes snapshot do
        assert_equal @blob.id, ReplaceW9.call(vendor: @vendor, file: reference).id
      end

      assert_predicate @vendor, :w9_status_rejected?
      assert_equal @blob.id, review.reload.reviewed_blob_id
    end

    private

    def decide(status: 'approved')
      ReviewW9.new(vendor: @vendor, admin: @admin,
                   attributes: { status: status, reviewed_blob_id: @blob.id,
                                 rejection_reason_code: 'other', rejection_reason: 'Please correct the document.' }).call
    end

    def upload
      Rack::Test::UploadedFile.new(file_fixture('sample_w9.pdf'), 'application/pdf')
    end
  end
end
