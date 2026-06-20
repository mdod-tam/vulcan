# frozen_string_literal: true

require 'test_helper'

class MedicalProviderMailerTest < ActionMailer::TestCase
  setup do
    @constituent = create(:constituent, :with_address_and_phone)
    @application = create(:application,
                          user: @constituent,
                          medical_provider_email: 'provider@example.com',
                          medical_provider_name: 'Dr. Smith')

    # Stub EmailTemplate.find_by! to return mocks with render methods
    request_cert_template_mock = mock('request_cert_template')
    # Stub render to accept the variables hash and return the expected subject and body strings
    request_cert_template_mock.stubs(:render).returns(["Mock Request Cert Subject for #{@constituent.full_name}",
                                                       "Mock Request Cert Body for #{@constituent.full_name}"])
    EmailTemplate.stubs(:find_by!).with(name: 'medical_provider_request_certification', format: :text, locale: 'en').returns(request_cert_template_mock)

    rejected_template_mock = mock('rejected_template')
    rejected_template_mock.stubs(:render).returns(["Certification Rejected: #{@constituent.full_name}",
                                                   'Text Rejection Reason: Incomplete documentation, Expired license'])
    EmailTemplate.stubs(:find_by!).with(name: 'medical_provider_certification_rejected', format: :text, locale: 'en').returns(rejected_template_mock)
  end

  test 'request_certification' do
    # Use capture_emails with deliver_now for immediate execution and .with syntax
    emails = capture_emails do
      MedicalProviderMailer.with(application: @application).request_certification.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@application.medical_provider_email], email.to
    assert_equal [Policy.get('support_email') || 'mat.program1@maryland.gov'], email.reply_to
    # Assert against the rendered subject from the mock template
    expected_subject = "Mock Request Cert Subject for #{@constituent.full_name}"
    assert_equal expected_subject, email.subject

    # Assert against the rendered text body from the mock template
    expected_text_body = "Mock Request Cert Body for #{@constituent.full_name}"
    assert_includes email.body.to_s, expected_text_body
  end

  test 'certification_rejected' do
    # Create test data with rejection reasons
    rejection_reason = 'Incomplete documentation, Expired license'

    # Use capture_emails with deliver_now for immediate execution and .with syntax
    emails = capture_emails do
      MedicalProviderMailer.with(
        application: @application,
        rejection_reason: rejection_reason,
        admin: create(:admin)
      ).certification_rejected.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    # Verify email basics
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@application.medical_provider_email], email.to
    assert_match(/Certification/i, email.subject)
  end

  test 'build_rejection_variables includes secure upload resubmission instructions when provided' do
    mailer = MedicalProviderMailer.new
    mailer.params = {
      application: @application,
      rejection_reason: 'Missing signature',
      admin: create(:admin),
      secure_upload_url: 'https://example.test/secure_certification_form?token=abc'
    }

    variables = mailer.send(:build_rejection_variables)

    assert variables[:download_form_url].present?
    assert_match %r{/medical_certification_form\z}, variables[:download_form_url]
    assert_equal 'https://example.test/secure_certification_form?token=abc', variables[:secure_upload_url]
    assert_includes variables[:certification_resubmission_instructions], 'Secure certification upload link'
    assert_includes variables[:certification_resubmission_instructions], variables[:secure_upload_url]
  end

  test 'build_rejection_variables omits secure upload resubmission step when no secure upload URL exists' do
    mailer = MedicalProviderMailer.new
    mailer.params = {
      application: @application,
      rejection_reason: 'Missing signature',
      admin: create(:admin)
    }

    variables = mailer.send(:build_rejection_variables)

    assert_equal '', variables[:secure_upload_url]
    assert_includes variables[:certification_resubmission_instructions], 'Blank disability certification form'
    assert_not_includes variables[:certification_resubmission_instructions], 'Secure certification upload link'
  end

  test 'build_request_certification_variables includes constituent contact info and static form URL' do
    mailer = MedicalProviderMailer.new
    mailer.params = {
      application: @application,
      timestamp: Time.current.iso8601
    }

    variables = mailer.send(:build_request_certification_variables)

    assert_equal @constituent.phone, variables[:constituent_phone_formatted]
    assert_equal @constituent.email, variables[:constituent_email]
    assert_match %r{/medical_certification_form\z}, variables[:download_form_url]
    assert_includes variables[:certification_submission_instructions], 'Return the completed form by fax'
    assert_not_includes variables[:certification_submission_instructions], 'disability_cert@mdmat.org'
    assert_equal '', variables[:secure_upload_url]
  end

  test 'build_request_certification_variables includes secure upload instructions when provided' do
    mailer = MedicalProviderMailer.new
    mailer.params = {
      application: @application,
      timestamp: Time.current.iso8601,
      secure_upload_url: 'https://example.test/secure_certification_form?token=abc'
    }

    variables = mailer.send(:build_request_certification_variables)

    assert_equal 'https://example.test/secure_certification_form?token=abc', variables[:secure_upload_url]
    assert_includes variables[:certification_submission_instructions], 'Secure certification upload link'
    assert_includes variables[:certification_submission_instructions], variables[:secure_upload_url]
  end

  test 'certification error logging redacts secure upload URLs' do
    mailer = MedicalProviderMailer.new
    original_logger = Rails.logger
    log_output = StringIO.new
    raw_url = 'https://example.test/secure_certification_form?token=secret-token'
    error = StandardError.new("smtp failure for #{raw_url}")
    error.set_backtrace(["app/mailers/example.rb:1:in `#{raw_url}'"])
    Rails.logger = ActiveSupport::Logger.new(log_output)

    mailer.send(:log_certification_error, 'request_certification', 'provider@example.test', error)

    log_message = log_output.string
    assert_includes log_message, '[REDACTED_URL]'
    assert_not_includes log_message, raw_url
    assert_not_includes log_message, 'secret-token'
  ensure
    Rails.logger = original_logger
  end

  test 'certification_rejected uses locale-aware base template name for spanish recipients' do
    @constituent.update!(locale: 'es')

    spanish_template = mock('spanish_rejected_template')
    spanish_template.stubs(:render).returns(['Certificacion rechazada', 'Motivo traducido'])
    EmailTemplate.expects(:find_by!).with(
      name: 'medical_provider_certification_rejected',
      format: :text,
      locale: 'es'
    ).returns(spanish_template)

    email = MedicalProviderMailer.with(
      application: @application,
      rejection_reason: 'Falta informacion',
      admin: create(:admin)
    ).certification_rejected

    assert_equal [@application.medical_provider_email], email.to
    assert_equal 'Certificacion rechazada', email.subject
  end
end
