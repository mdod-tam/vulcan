# frozen_string_literal: true

require 'test_helper'

class CertifyingProfessionalMailerTest < ActionMailer::TestCase
  setup do
    load_seeded_email_templates('certifying_professional_request_certification', 'certifying_professional_certification_rejected')
    @constituent = create(:constituent, :with_address_and_phone, locale: 'es', date_of_birth: Date.new(1990, 1, 2))
    @application = create(
      :application,
      skip_proofs: true,
      user: @constituent,
      disability_certification_request_count: 1,
      certifying_professional_email: 'provider@example.com',
      certifying_professional_name: 'Dr. Smith'
    )
  end

  test 'a first request delivers actual applicant contacts and fax instructions to the provider in English' do
    emails = capture_emails do
      CertifyingProfessionalMailer.with(application: @application).request_certification.deliver_now
    end
    assert_equal 1, emails.size
    email = emails.first
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@application.certifying_professional_email], email.to
    assert_equal [ProgramContact.support_email], email.reply_to
    assert_equal 'outbound', email.message_stream
    assert_equal 'DISABILITY CERTIFICATION FORM REQUEST', email.subject
    body = decoded_text_part(email)
    assert_includes body, "- Name: #{@constituent.full_name}"
    assert_includes body, '- Date of Birth: 01/02/1990'
    assert_includes body, "- Phone: #{@constituent.phone}"
    assert_includes body, "- Email: #{@constituent.email}"
    assert_includes body, '456 Oak Ave'
    assert_includes body, 'Apt 101'
    assert_includes body, 'Silver Spring, MD 20901'
    assert_includes body, "- Application ID: #{@application.id}"
    assert_includes body, Rails.application.routes.url_helpers.disability_certification_form_url(host: 'example.com')
    assert_includes body, 'Return the completed form by fax to (410) 767-4276'
    assert_includes body, ProgramContact.support_email
    assert_not_includes body, 'This is a follow-up request'
    assert_not_includes body, 'Secure certification upload link:'
  end

  test 'a secure follow-up request uses the recorded provider recipient and real upload instructions' do
    @application.update!(disability_certification_request_count: 2)
    secure_url = 'https://example.test/secure_certification_form?token=request-proof'
    emails = capture_emails do
      CertifyingProfessionalMailer.with(application: @application, recipient_email: 'issued.provider@example.test',
                                        secure_upload_url: secure_url).request_certification.deliver_now
    end
    assert_equal 1, emails.size
    email = emails.first
    assert_equal ['issued.provider@example.test'], email.to
    body = decoded_text_part(email)
    assert_includes body, 'This is a follow-up request (Request #2)'
    assert_includes body, 'Secure certification upload link:'
    assert_includes body, secure_url
    assert_includes body, 'Blank disability certification form:'
    assert_not_includes body, 'Return the completed form by fax'
  end

  test 'rejection without a secure link delivers the actual English reason and fax instructions for a Spanish applicant' do
    emails = I18n.with_locale(:es) do
      capture_emails do
        CertifyingProfessionalMailer.with(application: @application, rejection_reason: 'Missing provider signature').certification_rejected.deliver_now
      end
    end
    assert_equal 1, emails.size
    email = emails.first
    assert_equal [@application.certifying_professional_email], email.to
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal 'Disability Certification Rejected', email.subject
    body = decoded_text_part(email)
    assert_includes body, @constituent.full_name
    assert_includes body, "Application ID: #{@application.id}"
    assert_includes body, 'Missing provider signature'
    assert_includes body, 'Blank disability certification form:'
    assert_includes body, 'Fax: Send the updated form to 410-767-4276'
    assert_not_includes body, 'Secure certification upload link:'
  end

  test 'rejection with a secure link delivers the actual resubmission link and blank form URL' do
    secure_url = 'https://example.test/secure_certification_form?token=retry-proof'
    emails = capture_emails do
      CertifyingProfessionalMailer.with(application: @application, rejection_reason: 'Missing provider signature',
                                        recipient_email: 'issued.rejection@example.test', secure_upload_url: secure_url).certification_rejected.deliver_now
    end
    assert_equal 1, emails.size
    assert_equal ['issued.rejection@example.test'], emails.first.to
    body = decoded_text_part(emails.first)
    assert_includes body, 'Missing provider signature'
    assert_includes body, 'Secure certification upload link:'
    assert_includes body, secure_url
    assert_includes body, Rails.application.routes.url_helpers.disability_certification_form_url(host: 'example.com')
  end

  test 'a public request propagates a rendering failure without delivery or private exception details in its log' do
    log_output = StringIO.new
    logger = ActiveSupport::Logger.new(log_output)
    raw_url = 'https://example.test/secure_certification_form?token=secret-token'
    error = StandardError.new("template failure for #{raw_url}")
    error.set_backtrace(["app/services/example.rb:1:in `#{raw_url}'"])
    EmailTemplates::Renderer.expects(:render).once.raises(error)

    Rails.stub(:logger, logger) do
      assert_no_emails do
        raised = assert_raises(StandardError) do
          CertifyingProfessionalMailer.with(application: @application, secure_upload_url: raw_url).request_certification.deliver_now
        end
        assert_same error, raised
      end
    end
    assert_includes log_output.string, "application #{@application.id}"
    assert_includes log_output.string, 'StandardError'
    assert_not_includes log_output.string, raw_url
    assert_not_includes log_output.string, 'secret-token'
  end
end
