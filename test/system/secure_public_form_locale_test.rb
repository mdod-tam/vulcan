# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

class SecurePublicFormLocaleTest < ApplicationSystemTestCase
  include SystemTestEvidence

  test 'vendor W9 form renders show and validation errors in the vendor locale' do
    vendor = create(:vendor, :with_w9, locale: 'es')
    raw_token = VendorSecureRequestForm.generate_public_token
    create(:vendor_secure_request_form, vendor: vendor, raw_token: raw_token)

    visit secure_w9_form_path(token: raw_token)

    assert_selector 'html[lang="es"]'
    assert_selector 'h1', text: I18n.t('secure_w9_forms.show.heading', locale: :es)
    assert_no_text I18n.t('secure_w9_forms.show.heading', locale: :en)
    take_evidence_screenshot('secure-w9-vendor-spanish-locale', full: true, html: true)

    submit_form_without_file

    assert_selector 'html[lang="es"]'
    assert_selector '#error-summary-title', text: I18n.t('secure_w9_forms.show.error_summary', locale: :es)
    assert_selector '#file_error', text: I18n.t('vendors.w9_resubmission.messages.file_blank', locale: :es)
    take_evidence_screenshot('secure-w9-vendor-spanish-validation', full: true, html: true)
  end

  test 'certification form renders show and validation errors in the applicant locale' do
    constituent = create(:constituent, locale: 'es')
    application = create(
      :application,
      :in_progress,
      user: constituent,
      medical_provider_name: 'Dra. Proveedora',
      medical_provider_email: 'provider-locale@example.com'
    )
    raw_token = MedicalProviderSecureRequestForm.generate_public_token
    create(:medical_provider_secure_request_form, application: application, raw_token: raw_token)

    visit secure_certification_form_path(token: raw_token)

    assert_selector 'html[lang="es"]'
    assert_selector 'h1', text: I18n.t('secure_certification_forms.show.heading', locale: :es)
    assert_no_text I18n.t('secure_certification_forms.show.heading', locale: :en)
    take_evidence_screenshot('secure-certification-applicant-spanish-locale', full: true, html: true)

    submit_form_without_file

    assert_selector 'html[lang="es"]'
    assert_selector '#error-summary-title', text: I18n.t('secure_certification_forms.show.error_summary', locale: :es)
    assert_selector '#file_error', text: I18n.t('applications.certification_upload.messages.file_blank', locale: :es)
    take_evidence_screenshot('secure-certification-applicant-spanish-validation', full: true, html: true)
  end

  private

  def submit_form_without_file
    page.execute_script(<<~JS)
      const form = document.querySelector('form');
      HTMLFormElement.prototype.submit.call(form);
    JS
  end
end
