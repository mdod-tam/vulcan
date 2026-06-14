# frozen_string_literal: true

require 'test_helper'

class MedicalProviderRequestCertificationTemplateTest < ActionMailer::TestCase
  setup do
    EmailTemplate.where(name: 'medical_provider_request_certification', format: :text).delete_all
    load Rails.root.join('db/seeds/email_templates/medical_provider_request_certification.rb')

    @constituent = create(:constituent, :with_address_and_phone, first_name: 'Alex', last_name: 'Smith')
    @application = create(
      :application,
      user: @constituent,
      medical_provider_name: 'Dr. Certifier',
      medical_provider_email: 'provider@example.test'
    )
  end

  test 'initial secure certification request does not render sent timestamp sentence' do
    email = MedicalProviderMailer.with(
      application: @application,
      timestamp: Time.zone.local(2026, 5, 7, 15, 27).iso8601,
      secure_upload_url: 'https://example.test/secure_certification_form?token=abc'
    ).request_certification

    body = decoded_text_part(email)

    assert email.multipart?
    assert_includes body, 'DISABILITY CERTIFICATION FORM REQUEST'
    assert_includes body, 'Alex Smith'
    assert_includes body, 'Secure certification upload link'
    assert_accessible_html_link email,
                                href: 'https://example.test/secure_certification_form?token=abc',
                                text: 'Secure certification upload link'
    assert_not_includes body, 'and was sent on'
    assert_not_includes body, 'May 07, 2026'
  end
end
