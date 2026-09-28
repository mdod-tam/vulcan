# frozen_string_literal: true

require 'test_helper'

# Runs real vendor notices through their production callers and the mail delivery job.
class VendorMailDispatchTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @admin = create(:admin)
    @vendor = create(:vendor, :with_w9)
    load_seeded_email_templates('vendor_notifications_w9_approved', 'vendor_notifications_payment_issued')
    ActionMailer::Base.deliveries.clear
  end

  test 'approving a W9 delivers one approval notice to the vendor' do
    perform_enqueued_jobs do
      W9Review.create!(vendor: @vendor, admin: @admin, status: :approved, reviewed_at: Time.current)
    end

    notification = Notification.find_by!(action: 'w9_approved', recipient: @vendor)
    assert_nil notification.delivery_status
    assert_equal 'email', notification.metadata['actual_delivery_channel']
    assert_equal [[@vendor.email]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'a disabled W9 approval template sends nothing and keeps the approval' do
    EmailTemplate.where(name: 'vendor_notifications_w9_approved').update_all(enabled: false)

    perform_enqueued_jobs do
      W9Review.create!(vendor: @vendor, admin: @admin, status: :approved, reviewed_at: Time.current)
    end

    assert @vendor.reload.w9_status_approved?
    assert_empty ActionMailer::Base.deliveries
  end

  test 'the W9 rejection notification is audit-only' do
    notification = nil
    perform_enqueued_jobs do
      notification = NotificationService.create_and_deliver!(
        type: 'w9_rejected', recipient: @vendor, actor: @admin, notifiable: @vendor, channel: :email
      )
    end

    assert_equal 'none', notification.reload.metadata['actual_delivery_channel']
    assert_empty ActionMailer::Base.deliveries
  end

  test 'recording an invoice payment delivers the payment notice after commit' do
    invoice = create(:invoice, vendor: @vendor)

    perform_enqueued_jobs do
      invoice.update!(status: :invoice_paid, gad_invoice_reference: 'GAD-123')
    end

    mail = ActionMailer::Base.deliveries.sole
    assert_equal [@vendor.email], mail.to
    assert_includes mail.body.decoded, invoice.invoice_number
  end
end
