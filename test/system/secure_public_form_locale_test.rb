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
    assert_selector '#file_error', text: I18n.t('documents.refused.missing', locale: :es)
    take_evidence_screenshot('secure-w9-vendor-spanish-validation', full: true, html: true)
  end

  # The certification form is completed by the medical provider, not the applicant, so it uses the
  # default locale whatever the applicant's language (MedicalProviderSecureRequestForm#delivery_locale).
  test 'certification form renders show and validation errors in the default locale for a Spanish-speaking applicant' do
    ensure_system_audit_actor! # certification submissions are recorded by the system actor
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

    assert_selector "html[lang='#{I18n.default_locale}']"
    assert_selector 'h1', text: I18n.t('secure_certification_forms.show.heading', locale: I18n.default_locale)
    assert_no_text I18n.t('secure_certification_forms.show.heading', locale: :es)
    take_evidence_screenshot('secure-certification-default-locale', full: true, html: true)

    submit_form_without_file

    assert_selector "html[lang='#{I18n.default_locale}']"
    assert_selector '#error-summary-title',
                    text: I18n.t('secure_certification_forms.show.error_summary', locale: I18n.default_locale)
    assert_selector '#file_error', text: I18n.t('documents.refused.missing', locale: I18n.default_locale)
    take_evidence_screenshot('secure-certification-default-locale-validation', full: true, html: true)
  end

  private

  def submit_form_without_file
    page.execute_script(<<~JS)
      const form = document.querySelector('form');
      HTMLFormElement.prototype.submit.call(form);
    JS
  end
end
