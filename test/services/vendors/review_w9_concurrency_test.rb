# frozen_string_literal: true

require 'test_helper'

module Vendors
  class ReviewW9ConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    test 'concurrent decisions produce one document decision and one audit' do
      vendor = create(:vendor, :with_w9)
      admin = create(:admin)
      blob_id = vendor.w9_form.blob.id
      ready = Queue.new
      release = Queue.new
      holder_pid_queue = Queue.new
      winner = nil
      loser = nil
      holder = on_own_connection do
        holder_pid_queue << backend_pid
        User.find(vendor.id).with_lock do
          winner = decide(vendor.id, admin.id, blob_id)
          ready << true
          release.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(ready, thread: holder)
      contender_pid_queue = Queue.new
      contender = on_own_connection do
        contender_pid_queue << backend_pid
        loser = decide(vendor.id, admin.id, blob_id)
      end
      confirm_blocked_then_release(wait_for_signal(contender_pid_queue, thread: contender), holder_pid: holder_pid,
                                                                                            release_queue: release, holder_thread: holder, contender_thread: contender)

      assert_predicate winner, :success?
      assert_predicate loser, :failure?
      assert_equal 1, vendor.w9_reviews.count
      assert_equal 1, Event.where(auditable: vendor, action: 'w9_approved').count
      assert_predicate vendor.reload, :w9_status_approved?
      assert_equal 0, vendor.w9_rejections_count
    ensure
      cleanup(vendor, admin)
    end

    test 'post commit notification failure leaves a successful recorded decision with failed delivery' do
      vendor = create(:vendor, :with_w9)
      admin = create(:admin)
      NotificationService.stubs(:create_and_deliver!).raises(IOError, 'mail unavailable')

      result = decide(vendor.id, admin.id, vendor.w9_form.blob.id)

      assert_predicate result, :success?
      assert_equal 'failed', result.data[:delivery]
      assert_predicate vendor.reload, :w9_status_approved?
      assert_equal 1, vendor.w9_reviews.count
      assert_equal 1, Event.where(auditable: vendor, action: 'w9_approved').count
      assert_predicate decide(vendor.id, admin.id, vendor.w9_form.blob.id), :failure?
    ensure
      cleanup(vendor, admin)
    end

    private

    def decide(vendor_id, admin_id, blob_id)
      ReviewW9.new(vendor: Users::Vendor.find(vendor_id), admin: User.find(admin_id),
                   attributes: { status: 'approved', reviewed_blob_id: blob_id }).call
    end

    def cleanup(vendor, admin)
      return unless vendor

      W9Review.where(vendor_id: vendor.id).delete_all
      vendor.vendor_secure_request_forms.destroy_all
      ActiveStorage::Attachment.where(record: vendor).delete_all
      cleanup_duplicate_review_test_data!(vendor, admin)
    end
  end
end
