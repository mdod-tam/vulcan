# frozen_string_literal: true

require 'test_helper'

# Runs real vendor notices through their production callers and the mail delivery job.
class VendorMailDispatchTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ActiveJob::TestHelper
  include ConcurrencyTestHelper

  setup do
    @system_actor_existed = PublicAuditActor.system_audit_actor.present?
    @system_actor = ensure_system_audit_actor!
    @admin = create(:admin)
    @vendor = create(:vendor, :with_w9)
    load_seeded_email_templates('vendor_notifications_w9_approved', 'vendor_notifications_w9_rejected',
                                'vendor_notifications_payment_issued')
    @approval_template_controls = EmailTemplate.where(name: 'vendor_notifications_w9_approved').to_h do |template|
      [template.id, template.slice(:enabled, :delivery_generation, :updated_by_id, :updated_at)]
    end
    clear_enqueued_jobs
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    # Real commits require restoring the template controls before removing their test actor.
    @approval_template_controls.each { |id, values| EmailTemplate.find(id).update_columns(values) }
    W9Review.where(vendor: @vendor).delete_all
    @vendor.vendor_secure_request_forms.destroy_all
    if @invoice
      # Remove this committed test record without weakening the issued-invoice deletion guard.
      Event.where(auditable: @invoice).delete_all
      EmailDeliveryAttempt.where(origin: @invoice).delete_all
      Invoice.where(id: @invoice.id).delete_all
    end
    ActiveStorage::Attachment.where(record: @vendor).delete_all
    cleanup_duplicate_review_test_data!(@vendor, @admin, (@system_actor unless @system_actor_existed))
    clear_enqueued_jobs
  end

  test 'approving a W9 delivers one approval notice to the vendor' do
    perform_enqueued_jobs do
      record_decision(:approved)
    end

    notification = Notification.find_by!(action: 'w9_approved', recipient: @vendor)
    assert_equal 'queued', notification.delivery_status
    assert_empty notification.email_delivery_attempts
    assert_equal 'email', notification.metadata['actual_delivery_channel']
    assert_equal [[@vendor.email]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'a disabled W9 approval template sends nothing and keeps the approval' do
    EmailDelivery::ControlWriter.set_template_pair(name: 'vendor_notifications_w9_approved', format: :text,
                                                   enabled: false, actor: @admin, operation_id: SecureRandom.uuid)

    perform_enqueued_jobs do
      record_decision(:approved)
    end

    assert @vendor.reload.w9_status_approved?
    notification = Notification.find_by!(action: 'w9_approved', recipient: @vendor)
    assert_equal 'suppressed', notification.delivery_status
    assert_equal 'template_disabled', notification.metadata.dig('delivery_suppressed', 'reason')
    assert_empty ActionMailer::Base.deliveries
  end

  test 'review rejection records an audit-only decision and sends a separate secure upload notice' do
    perform_enqueued_jobs do
      record_decision(:rejected)
    end

    notification = Notification.find_by!(action: 'w9_rejected', recipient: @vendor)
    assert_nil notification.reload.delivery_status
    assert_empty notification.email_delivery_attempts
    assert_not Event.exists?(auditable: notification, action: 'notification_w9_rejected_sent')
    assert @vendor.reload.w9_status_rejected?
    assert_equal 1, @vendor.w9_rejections_count
    request_form = @vendor.vendor_secure_request_forms.sole
    assert_equal @vendor.email, request_form.recipient_email
    assert_equal [[@vendor.email]], ActionMailer::Base.deliveries.map(&:to)
    assert_includes decoded_text_part(ActionMailer::Base.deliveries.sole), 'Secure W9 upload link'
  end

  test 'recording an invoice payment delivers the payment notice after commit' do
    @invoice = create(:invoice, :pending, vendor: @vendor)

    perform_enqueued_jobs do
      pay_invoice!(@invoice, actor: @admin, gad_invoice_reference: 'GAD-123')
    end

    mail = ActionMailer::Base.deliveries.sole
    assert_equal [@vendor.email], mail.to
    assert_includes mail.body.decoded, @invoice.invoice_number
  end

  private

  def record_decision(status)
    blob_id = @vendor.w9_form.blob.id
    result = Vendors::ReviewW9.new(vendor: @vendor, admin: @admin,
                                   attributes: { status: status.to_s, reviewed_blob_id: blob_id,
                                                 rejection_reason_code: 'tax_id_mismatch', rejection_reason: 'Tax ID mismatch' }).call

    assert_predicate result, :success?
    assert_equal blob_id, result.data.fetch(:review).reload.reviewed_blob_id
    result
  end
end
