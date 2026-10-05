# frozen_string_literal: true

require 'test_helper'

class VendorNotificationsMailerTest < ActionMailer::TestCase
  def mock_template(subject_format, body_format)
    template_instance = mock("email_template_instance_#{subject_format.gsub(/\s+/, '_')}")

    template_instance.stubs(:render).with(any_parameters).returns do |**vars|
      rendered_subject = subject_format
      rendered_body = if vars[:invoice_number]
                        body_format.gsub('%<invoice_number>s', vars[:invoice_number])
                      elsif vars[:rejection_reason]
                        body_format.gsub('%<rejection_reason>s', vars[:rejection_reason])
                      else
                        body_format
                      end
      [rendered_subject, rendered_body]
    end

    template_instance.stubs(:subject).returns(subject_format)
    template_instance.stubs(:render_subject).returns(subject_format)
    template_instance.stubs(:body).returns(body_format)

    template_instance
  end

  setup do
    @vendor = create(:vendor)
    @invoice = create(:invoice, vendor: @vendor)
    @transactions = create_list(:voucher_transaction, 3, invoice: @invoice, vendor: @vendor)

    rejected_template = mock_template(
      'Mock W9 Rejected Subject',
      'Mock W9 Rejected Body %<rejection_reason>s'
    )

    approved_template = mock_template(
      'Mock W9 Approved Subject',
      'Mock W9 Approved Body'
    )

    payment_template = mock_template(
      'Mock Payment Issued Subject',
      'Mock Payment Issued Body %<invoice_number>s'
    )

    EmailTemplate.stubs(:find_by!)
                 .with(name: 'vendor_notifications_w9_rejected', format: :text, locale: 'en')
                 .returns(rejected_template)

    EmailTemplate.stubs(:find_by!)
                 .with(name: 'vendor_notifications_w9_approved', format: :text, locale: 'en')
                 .returns(approved_template)

    EmailTemplate.stubs(:find_by!)
                 .with(name: 'vendor_notifications_payment_issued', format: :text, locale: 'en')
                 .returns(payment_template)
  end

  test 'invoice_generated' do
    skip 'Add invoice-generated email and PDF attachment assertions before enabling this test'
  end

  test 'payment_issued' do
    expected_text = "Mock Payment Issued Body #{@invoice.invoice_number}"
    payment_template = mock('payment_template_specific')
    payment_template.stubs(:subject).returns('Payment issued')
    payment_template.stubs(:render_subject).returns('Payment issued')
    payment_template.stubs(:enabled?).returns(true)
    payment_template.stubs(:render).returns(['Payment issued', expected_text])

    EmailTemplate.unstub(:find_by!)
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'vendor_notifications_payment_issued', format: :text, locale: 'en')
                 .returns(payment_template)

    emails = capture_emails do
      VendorNotificationsMailer.with(invoice: @invoice).payment_issued.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@vendor.email], email.to
    assert_equal 'Payment issued', email.subject

    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_equal 'text/plain; charset=UTF-8', email.content_type

    assert_includes email.body.to_s, expected_text
  end

  test 'payment_issued renders a real Liquid text template' do
    EmailTemplate.unstub(:find_by!)
    create_real_text_email_template(
      name: 'vendor_notifications_payment_issued',
      subject: 'Payment {{ invoice_number }}',
      body: 'Paid {{ invoice_number }} for {{ vendor_business_name }} totaling {{ total_amount_formatted }}',
      required: %w[invoice_number vendor_business_name total_amount_formatted]
    )

    email = VendorNotificationsMailer.with(invoice: @invoice).payment_issued.deliver_now

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@vendor.email], email.to
    assert_equal "Payment #{@invoice.invoice_number}", email.subject
    assert_includes email.body.to_s, @invoice.invoice_number
    assert_includes email.body.to_s, @vendor.business_name
  end

  test 'w9_approved' do
    expected_text = 'Mock W9 Approved Body'
    approved_template = mock('approved_template_specific')
    approved_template.stubs(:subject).returns('W9 approved')
    approved_template.stubs(:render_subject).returns('W9 approved')
    approved_template.stubs(:enabled?).returns(true)
    approved_template.stubs(:render).returns(['W9 approved', expected_text])

    EmailTemplate.stubs(:find_by!)
                 .with(name: 'vendor_notifications_w9_approved', format: :text, locale: 'en')
                 .returns(approved_template)

    emails = capture_emails do
      VendorNotificationsMailer.with(vendor: @vendor).w9_approved.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@vendor.email], email.to
    assert_equal 'W9 approved', email.subject

    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    assert_includes email.body.to_s, expected_text
  end

  test 'w9_rejected' do
    Vendors::RequestW9Resubmission.any_instance.stubs(:call).returns(BaseService::Result.new(success: true, message: 'ok', data: {}))
    review = create(:w9_review, :rejected, vendor: @vendor)
    secure_upload_url = 'https://example.test/secure_w9_form?token=abc'
    EmailTemplate.unstub(:find_by!)

    emails = capture_emails do
      VendorNotificationsMailer.with(
        vendor: @vendor,
        w9_review: review,
        secure_upload_url: secure_upload_url
      ).w9_rejected.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@vendor.email], email.to
    assert_equal 'W9 Form Requires Correction', email.subject

    assert_includes decoded_text_part(email), review.rejection_reason
    assert_includes decoded_text_part(email), secure_upload_url
    assert_includes decoded_text_part(email), 'Secure W9 upload link'
  end

  test 'w9_upload_requested' do
    secure_upload_url = 'https://example.test/secure_w9_form?token=abc'

    emails = capture_emails do
      VendorNotificationsMailer.with(
        vendor: @vendor,
        secure_upload_url: secure_upload_url
      ).w9_upload_requested.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@vendor.email], email.to
    assert_equal "Secure W9 upload requested for #{@vendor.business_name}", email.subject
    assert_includes decoded_text_part(email), secure_upload_url
    assert_includes decoded_text_part(email), 'has requested a W9 form from you'
  end

  test 'mailer error audit metadata redacts secure upload URLs' do
    raw_url = 'https://example.test/secure_w9_form?token=secret-token'

    assert_difference -> { Event.where(action: 'email_delivery_error', auditable: @vendor).count }, 1 do
      VendorNotificationsMailer.new.send(
        :log_mail_error,
        StandardError.new("boom #{raw_url}"),
        @vendor,
        'vendor_notifications_w9_rejected'
      )
    end

    event = Event.where(action: 'email_delivery_error', auditable: @vendor).last

    assert_includes event.metadata.fetch('error_message'), '[REDACTED_URL]'
    assert_not_includes event.metadata.fetch('error_message'), raw_url
    assert_not event.metadata.key?('variables')
  end

  test 'w9_expiring_soon renders stored template with required variables' do
    EmailTemplate.unstub(:find_by!)
    EmailTemplate.where(name: 'vendor_notifications_w9_expiring_soon', format: :text).delete_all
    load Rails.root.join('db/seeds/email_templates/vendor_notifications_w9_expiring_soon.rb')

    expiration_date = 14.days.from_now.to_date
    @vendor.stubs(:w9_expiration_date).returns(expiration_date)
    @vendor.stubs(:associated?).returns(false)
    VendorNotificationsMailer.any_instance.stubs(:resolve_vendor_portal_url).returns('https://example.test/vendor_portal')

    emails = capture_emails do
      VendorNotificationsMailer.with(vendor: @vendor).w9_expiring_soon.deliver_now
    end

    assert_equal 1, emails.size
    body = decoded_text_part(emails.first)

    assert_includes body, @vendor.business_name
    assert_includes body, expiration_date.strftime('%B %d, %Y')
    assert_includes body, 'https://example.test/vendor_portal'
    assert_includes body, 'Vendor portal link:'
    assert_not_includes body, '%<status_box_warning_text>'
  end

  test 'w9_expired renders stored template with required variables' do
    EmailTemplate.unstub(:find_by!)
    EmailTemplate.where(name: 'vendor_notifications_w9_expired', format: :text).delete_all
    load Rails.root.join('db/seeds/email_templates/vendor_notifications_w9_expired.rb')

    expiration_date = 7.days.ago.to_date
    @vendor.stubs(:w9_expiration_date).returns(expiration_date)
    @vendor.stubs(:associated?).returns(true)
    VendorNotificationsMailer.any_instance.stubs(:resolve_vendor_portal_url).returns('https://example.test/vendor_portal')

    emails = capture_emails do
      VendorNotificationsMailer.with(vendor: @vendor).w9_expired.deliver_now
    end

    assert_equal 1, emails.size
    body = decoded_text_part(emails.first)

    assert_includes body, @vendor.business_name
    assert_includes body, expiration_date.strftime('%B %d, %Y')
    assert_includes body, 'https://example.test/vendor_portal'
    assert_includes body, 'Vendor portal link:'
    assert_includes body, 'Association Requirement'
    assert_not_includes body, '%<status_box_error_text>'
    assert_not_includes body, '%<status_box_warning_text>'
  end
end
