# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

# A link can be revoked while its page is open. Submitting it must show the
# current state instead of leaving the user on a form that silently does nothing.
class SecureFormTerminalStateTest < ApplicationSystemTestCase
  include SystemTestEvidence

  test 'proof upload on a link revoked after the page loaded shows the unavailable page' do
    raw_token = SecureRequestForm.generate_public_token
    form = create(:secure_request_form, kind: :income_proof_resubmission, raw_token: raw_token)

    visit secure_proof_form_path(token: raw_token)
    assert_selector 'h1', text: I18n.t('secure_proof_forms.show.heading',
                                       proof_type: I18n.t('secure_proof_forms.proof_types.income'))
    form.revoke!(reason: 'system test')

    attach_file 'file', Rails.root.join('test/fixtures/files/income_proof.pdf'), make_visible: true
    click_button I18n.t('secure_proof_forms.show.submit')

    assert_selector 'h1', text: I18n.t('secure_proof_forms.unavailable.heading')
    take_evidence_screenshot('secure-proof-revoked-after-load', full: true, html: true)
  end

  test 'provider information on a link submitted in another tab shows the submitted page' do
    raw_token = SecureRequestForm.generate_public_token
    form = create(:secure_request_form, kind: :provider_info_request, raw_token: raw_token)

    visit secure_provider_info_form_path(token: raw_token)
    assert_selector 'h1', text: I18n.t('secure_provider_info_forms.show.heading')
    form.mark_submitted!

    fill_in 'medical_provider_name', with: 'Dr. Second Tab'
    fill_in 'medical_provider_phone', with: '410-555-0100'
    fill_in 'medical_provider_email', with: 'second-tab@example.test'
    click_button I18n.t('secure_provider_info_forms.show.submit')

    assert_selector 'h1', text: I18n.t('secure_provider_info_forms.submitted.heading')
    take_evidence_screenshot('secure-provider-info-submitted-elsewhere', full: true, html: true)
  end

  test 'W9 upload on a revoked link shows the unavailable page through Turbo' do
    vendor = create(:vendor, :with_w9)
    raw_token = VendorSecureRequestForm.generate_public_token
    form = create(:vendor_secure_request_form, vendor: vendor, raw_token: raw_token)

    visit secure_w9_form_path(token: raw_token)
    assert_no_selector 'form[data-turbo="false"]'
    form.revoke!(reason: 'system test')

    attach_file 'file', Rails.root.join('test/fixtures/files/sample_w9.pdf'), make_visible: true
    click_button I18n.t('secure_w9_forms.show.submit')

    assert_selector 'h1', text: I18n.t('secure_w9_forms.unavailable.heading')
    take_evidence_screenshot('secure-w9-revoked-after-load', full: true, html: true)
  end

  test 'resend request lands on the neutral sent page' do
    raw_token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, kind: :income_proof_resubmission, raw_token: raw_token)
    Applications::RequestProofResubmission.any_instance.stubs(:call)
                                          .returns(BaseService::Result.new(success: true, message: 'ok', data: nil))

    visit new_secure_proof_form_resend_path(token: raw_token)
    click_button I18n.t('secure_proof_form_resends.new.submit')

    assert_selector 'h1', text: I18n.t('secure_proof_form_resends.create.heading')
    assert_current_path(%r{secure_proof_form_resend/sent})
    take_evidence_screenshot('secure-proof-resend-sent', full: true, html: true)
  end
end
