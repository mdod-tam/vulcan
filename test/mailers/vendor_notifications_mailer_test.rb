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

  test 'invoice payment and W9 notices use the vendor own email and locale despite guardian relationships' do
    EmailTemplate.unstub(:find_by!)
    guardian = create(:constituent, locale: 'es')
    create(:guardian_relationship, guardian_user: guardian, dependent_user: @vendor)
    assert_equal guardian.email, @vendor.effective_email, 'the generic dependent route would select the guardian'
    @vendor.update!(locale: 'en')
    load_seeded_email_templates('vendor_notifications_invoice_generated', 'vendor_notifications_payment_issued', 'vendor_notifications_w9_approved')

    emails = capture_emails do
      VendorNotificationsMailer.with(invoice: @invoice).invoice_generated.deliver_now
      VendorNotificationsMailer.with(invoice: @invoice).payment_issued.deliver_now
      VendorNotificationsMailer.with(vendor: @vendor).w9_approved.deliver_now
      VendorNotificationsMailer.with(vendor: @vendor, secure_upload_url: 'https://example.test/upload').w9_upload_requested.deliver_now
    end

    assert_equal [[@vendor.email]] * 4, emails.map(&:to)
    assert_equal 'W9 Form Approved', emails[2].subject
    assert_includes decoded_text_part(emails[2]), 'W9 approval and vendor authorization are separate steps'
    assert_not_includes decoded_text_part(emails[2]), 'now fully activated'
  end

  test 'secure W9 notices preserve the recipient snapshot after the vendor email changes' do
    EmailTemplate.unstub(:find_by!)
    snapshot = 'original.vendor@example.test'

    email = VendorNotificationsMailer.with(vendor: @vendor, recipient_email: snapshot,
                                           secure_upload_url: 'https://example.test/upload').w9_upload_requested.deliver_now

    assert_equal [snapshot], email.to
  end

  test 'a Spanish vendor receives Spanish W9 notices at their own email despite the English portal policy' do
    EmailTemplate.unstub(:find_by!)
    @vendor.update!(locale: 'es')
    guardian = create(:constituent, locale: 'en')
    create(:guardian_relationship, guardian_user: guardian, dependent_user: @vendor)
    @vendor.w9_form.attach(io: file_fixture('sample_w9.pdf').open, filename: 'w9.pdf', content_type: 'application/pdf')
    review = create(:w9_review, :rejected, vendor: @vendor, rejection_reason: 'El nombre fiscal no coincide.')
    load_seeded_email_templates('vendor_notifications_w9_approved', 'vendor_notifications_w9_rejected')

    emails = I18n.with_locale(:en) do
      capture_emails do
        VendorNotificationsMailer.with(vendor: @vendor).w9_approved.deliver_now
        VendorNotificationsMailer.with(vendor: @vendor, w9_review: review,
                                       secure_upload_url: 'https://example.test/upload').w9_rejected.deliver_now
      end
    end

    assert_equal [[@vendor.email]] * 2, emails.map(&:to)
    assert_equal 'Formulario W9 Aprobado', emails.first.subject
    assert_includes decoded_text_part(emails.first), I18n.t('vendor_onboarding.approval_notice.body', locale: :es)
    assert_equal 'El Formulario W9 Requiere Corrección', emails.last.subject
    rejected_text = decoded_text_part(emails.last)
    assert_includes rejected_text, I18n.t('vendor_notifications.w9_rejected.title', locale: :es)
    assert_includes rejected_text, I18n.t('vendor_notifications.w9_rejected.body', reason: review.rejection_reason, locale: :es)
    assert_includes rejected_text, 'Enlace seguro para cargar el formulario W9'
    assert_not_includes rejected_text, 'W9 Rejected'
    assert_not_includes rejected_text, 'Your W9 form requires attention'
  end

  test 'approval seeds preserve existing administrator content and delivery controls in both locales' do
    EmailTemplate.unstub(:find_by!)

    %w[en es].each do |locale|
      template = create_real_text_email_template(name: 'vendor_notifications_w9_approved', locale: locale,
                                                 subject: "Administrator #{locale} subject", body: "Administrator #{locale} body",
                                                 required: [])
      EmailDelivery::ControlWriter.set_template_pair(name: template.name, format: :text, enabled: false,
                                                     actor: create(:admin), operation_id: SecureRandom.uuid)
      original = template.reload.attributes
      suffix = locale == 'en' ? '' : '_es'

      load Rails.root.join("db/seeds/email_templates/vendor_notifications_w9_approved#{suffix}.rb")

      assert_equal original, template.reload.attributes
    end
  end

  test 'new invoice PDFs identify the vendor without their tax ID' do
    @vendor.update!(business_name: 'Private Tax Vendor', business_tax_id: '123456789')
    EmailTemplate.unstub(:find_by!)
    create_real_text_email_template(name: 'vendor_notifications_invoice_generated', subject: 'Invoice {{ invoice_number }}',
                                    body: 'Invoice {{ invoice_number }} for {{ vendor_business_name }}',
                                    required: %w[invoice_number vendor_business_name])

    email = VendorNotificationsMailer.with(invoice: @invoice).invoice_generated.message
    pdf = email.attachments["invoice-#{@invoice.invoice_number}.pdf"].decoded
    text = pdf.scan(/<([0-9a-f]+)>/i).map { |hex| [hex.first].pack('H*') }.join

    assert_includes text, 'Private Tax Vendor'
    assert_includes text, @invoice.invoice_number
    assert_not_includes text, '123456789'
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
    @vendor.w9_form.attach(io: file_fixture('sample_w9.pdf').open, filename: 'w9.pdf', content_type: 'application/pdf')
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
