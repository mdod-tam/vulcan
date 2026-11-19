# frozen_string_literal: true

require 'test_helper'

module Icanconnect
  class FinancialEvidenceBoundaryTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper
    include ActiveJob::TestHelper
    include IcanconnectTestSupport

    setup do
      @admin = create(:admin)
      @order, @unit = icc_order_with_unit
      @application = @unit.application
      @beneficiary = @application.user
      @product = @unit.product
      clear_enqueued_jobs
      clear_performed_jobs
    end

    teardown do
      clear_enqueued_jobs
      clear_performed_jobs
      remove_committed_evidence
      cleanup_duplicate_review_test_data!(@admin, @beneficiary)
    end

    test 'real has one replacement commits and purges its obsolete link while retaining filed invoice bytes' do
      writer = FilingWriter.new(actor: @admin)
      writer.mark!(selections: [filing_selection(@unit)], period: 'Test', external_reference: 'FILED')
      original_attachment = @order.financial_document.attachment
      original = original_attachment.blob
      replacement = icc_blob
      assert_performed_with(job: ActiveStorage::PurgeJob, args: [original]) do
        perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
          writer.correct!(record: @order, attributes: { financial_document: replacement }, lock_version: @order.reload.lock_version,
                          reason: 'Supplier corrected the invoice', external_reference: 'CORRECTION')
        end
      end
      assert_not ActiveStorage::Attachment.exists?(original_attachment.id)
      assert_equal replacement.id, @order.reload.financial_document.blob_id
      assert_includes @order.superseded_financial_documents.blobs.ids, original.id
      assert original.reload.service.exist?(original.key)
      assert_raises(ActiveRecord::RecordNotDestroyed) { @order.superseded_financial_documents.attachments.sole.purge }
    end

    test 'concurrent exact cost marks commit once and reject the stale reviewed selection' do
      selection = filing_selection(@unit)
      race!(
        -> { FilingWriter.new(actor: User.find(@admin.id)).mark!(selections: [selection], period: 'First', external_reference: 'FIRST') },
        -> { FilingWriter.new(actor: User.find(@admin.id)).mark!(selections: [selection], period: 'Second', external_reference: 'SECOND') }
      )
      assert_kind_of ActiveRecord::StaleObjectError, @contender_error
      assert_equal 'First', @unit.reload.icc_claim_period
      assert_equal 'FIRST', @unit.icc_external_filing_reference
      assert_equal 1, @unit.events.where(action: 'icc_cost_marked_claimed').count
      assert_not @order.reload.icc_claimed?
    end

    test 'an attachment purge waits for a concurrent filing and rechecks its stale owner before destroying evidence' do
      stale_attachment = @order.financial_document.attachment
      assert_not stale_attachment.record.icc_claimed?
      selection = filing_selection(@order)
      race!(
        -> { FilingWriter.new(actor: User.find(@admin.id)).mark!(selections: [selection], period: 'Test', external_reference: 'FILED') },
        -> { stale_attachment.purge }
      )
      assert_kind_of ActiveRecord::RecordNotDestroyed, @contender_error
      assert @order.reload.icc_claimed?
      assert @order.financial_document.attached?
      assert_equal stale_attachment.blob_id, @order.financial_document.blob_id
    end

    private

    def race!(first, second)
      holder_ready = Queue.new
      release_holder = Queue.new
      contender_pid = Queue.new
      @contender_error = nil
      holder = on_own_connection do
        ApplicationRecord.transaction do
          first.call
          holder_ready << backend_pid
          wait_for_signal(release_holder)
        end
      end
      holder_pid = wait_for_signal(holder_ready, thread: holder)
      contender = on_own_connection do
        contender_pid << backend_pid
        second.call
      rescue ActiveRecord::StaleObjectError, ActiveRecord::RecordNotDestroyed => e
        @contender_error = e
      end
      confirm_blocked_then_release(
        wait_for_signal(contender_pid, thread: contender),
        holder_pid: holder_pid, release_queue: release_holder, holder_thread: holder, contender_thread: contender
      )
    ensure
      release_holder << true if release_holder
      [holder, contender].compact.each { |thread| reap_thread(thread, timeout: 10, suppress_errors: !$ERROR_INFO.nil?) }
    end

    def remove_committed_evidence
      return unless @application

      attachments = ActiveStorage::Attachment.where(record_type: 'Application', record_id: @application.id)
                                             .or(ActiveStorage::Attachment.where(record_type: 'PurchaseOrder', record_id: @order.id))
      blobs = ActiveStorage::Blob.where(id: attachments.pluck(:blob_id)).to_a
      attachments.delete_all
      DocumentScan.where(blob_id: blobs.map(&:id)).delete_all
      blobs.each(&:purge)
      EquipmentItem.where(id: @unit.id).delete_all
      PurchaseOrder.where(id: @order.id).delete_all
      PrintQueueItem.where(application_id: @application.id).delete_all
      SecureRequestForm.where(application_id: @application.id).destroy_all
      ApplicationNote.where(application_id: @application.id).delete_all
      Notification.where(notifiable_type: 'Application', notifiable_id: @application.id).delete_all
      ApplicationStatusChange.where(application_id: @application.id).delete_all
      ProofReview.where(application_id: @application.id).delete_all
      Event.where(auditable_type: 'Application', auditable_id: @application.id).delete_all
      Application.where(id: @application.id).delete_all
      Product.where(id: @product.id).delete_all
    end
  end
end
