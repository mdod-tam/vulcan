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

    submission_error_template_mock = mock('submission_error_template')
    submission_error_template_mock.stubs(:render).returns(['Submission Error: error_test@example.com',
                                                           "Error: Invalid document format\nConstituent: #{@constituent.full_name}"])
    EmailTemplate.stubs(:find_by!).with(name: 'medical_provider_certification_submission_error',
                                        format: :text, locale: 'en').returns(submission_error_template_mock)
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
    # Assert against the rendered subject
    expected_subject = "Certification Rejected: #{@constituent.full_name}"
    assert_equal expected_subject, email.subject

    # Assert against the rendered text body
    assert_includes email.body.to_s, "Text Rejection Reason: #{rejection_reason}"
  end

  test 'certification_submission_error' do
    # Test with application
    provider = create(:medical_provider, email: 'error_test@example.com')
    error_message = 'Invalid document format'

    # Use capture_emails with deliver_now for immediate execution and .with syntax
    emails = capture_emails do
      MedicalProviderMailer.with(
        medical_provider: provider,
        application: @application,
        error_type: :invalid_format,
        message: error_message
      ).certification_submission_error.deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    # Verify email details
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [provider.email], email.to
    # Assert against the rendered subject
    expected_subject = "Submission Error: #{provider.email}"
    assert_equal expected_subject, email.subject

    # Verify content
    assert_includes email.body.to_s, "Error: #{error_message}"
    assert_includes email.body.to_s, @constituent.full_name
  end
end
