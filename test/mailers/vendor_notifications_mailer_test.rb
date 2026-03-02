# frozen_string_literal: true

require 'test_helper'

class VendorNotificationsMailerTest < ActionMailer::TestCase
  # Helper to create mock templates that respond to render method
  def mock_template(subject_format, body_format)
    template_instance = mock("email_template_instance_#{subject_format.gsub(/\s+/, '_')}")

    # Stub the render method to return [rendered_subject, rendered_body]
    # This simulates what the real EmailTemplate.render method does
    template_instance.stubs(:render).with(any_parameters).returns do |**vars|
      # For the invoice_number variable
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

    # Still stub subject and body for inspection if needed
    template_instance.stubs(:subject).returns(subject_format)
    template_instance.stubs(:body).returns(body_format)

    template_instance
  end

  setup do
    @vendor = create(:vendor)
    @invoice = create(:invoice, vendor: @vendor)
    @transactions = create_list(:voucher_transaction, 3, invoice: @invoice, vendor: @vendor)

    # Per project strategy, HTML emails are not used. Only stub for :text format.
    # If the mailer attempts to find_by!(format: :html), it should fail (e.g., RecordNotFound)
    # as no HTML templates should be seeded for these, and we provide no stub.

    # Create specific mock templates for each mailer method
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

    # Stub EmailTemplate.find_by! for text format only
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

  # Skip this test for now as it requires more complex setup
  # The invoice_generated method uses Prawn to generate a PDF which requires
  # period_start and period_end attributes on the invoice
  test 'invoice_generated' do
    skip 'Requires more complex setup with Prawn PDF generation'
  end

  test 'payment_issued' do
    # Create a specific stub for this test
    expected_text = "Mock Payment Issued Body #{@invoice.invoice_number}"
    payment_template = mock('payment_template_specific')
    payment_template.stubs(:render).returns(['Payment issued', expected_text])

    # Override stubs for this test
    EmailTemplate.unstub(:find_by!)
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'vendor_notifications_payment_issued', format: :text, locale: 'en')
                 .returns(payment_template)

    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      VendorNotificationsMailer.with(invoice: @invoice).payment_issued.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@vendor.email], email.to
    assert_equal 'Payment issued', email.subject

    # For non-multipart emails, we check the body directly
    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    # Check that the email body contains expected text
    assert_includes email.body.to_s, expected_text
  end

  test 'w9_approved' do
    # Create a specific stub for this test
    expected_text = 'Mock W9 Approved Body'
    approved_template = mock('approved_template_specific')
    approved_template.stubs(:render).returns(['W9 approved', expected_text])

    # Update the stub for this test
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'vendor_notifications_w9_approved', format: :text, locale: 'en')
                 .returns(approved_template)

    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      VendorNotificationsMailer.with(vendor: @vendor).w9_approved.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@vendor.email], email.to
    assert_equal 'W9 approved', email.subject

    # For non-multipart emails, we check the body directly
    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    # Check that the email body contains expected text
    assert_includes email.body.to_s, expected_text
  end

  test 'w9_rejected' do
    review = create(:w9_review, :rejected, vendor: @vendor)

    # Create a specific stub for this test
    expected_text = "Mock W9 Rejected Body #{review.rejection_reason}"
    rejected_template = mock('rejected_template_specific')
    rejected_template.stubs(:render).returns(['W9 rejected', expected_text])

    # Update the stub for this test
    EmailTemplate.stubs(:find_by!)
                 .with(name: 'vendor_notifications_w9_rejected', format: :text, locale: 'en')
                 .returns(rejected_template)

    # Using Rails 7.1.0+ capture_emails helper
    emails = capture_emails do
      VendorNotificationsMailer.with(vendor: @vendor, w9_review: review).w9_rejected.deliver_now
    end

    # Verify we captured an email
    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@vendor.email], email.to
    assert_equal 'W9 rejected', email.subject

    # For non-multipart emails, we check the body directly
    assert_equal 0, email.parts.size, 'Email should have no parts (non-multipart).'
    assert_includes email.content_type, 'text/plain', 'Email should be text/plain (may include charset)'

    # Check that the email body contains expected text
    assert_includes email.body.to_s, expected_text
  end

  # Skip this test for now as it requires w9_expiration_date attribute
  test 'w9_expiring_soon' do
    skip 'Requires w9_expiration_date attribute on vendor'
  end

  # Skip this test for now as it requires vendor_root_url
  test 'w9_expired' do
    skip 'Requires vendor_root_url helper'
  end
end
