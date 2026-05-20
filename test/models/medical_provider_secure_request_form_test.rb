# frozen_string_literal: true

require 'test_helper'

class MedicalProviderSecureRequestFormTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test 'belongs to application and snapshots provider email' do
    form = create(:medical_provider_secure_request_form)

    assert_equal form.application.medical_provider_email, form.provider_email
    assert_equal form.application.medical_provider_name, form.provider_name
  end

  test 'assigns request batch id before validation on create' do
    form = build(:medical_provider_secure_request_form, request_batch_id: nil)

    assert_nil form.request_batch_id

    form.valid?

    assert form.request_batch_id.present?
  end

  test 'from_public_token resolves the correct record via SHA-256 digest' do
    raw_token = MedicalProviderSecureRequestForm.generate_public_token
    form = create(:medical_provider_secure_request_form, raw_token: raw_token)

    found = MedicalProviderSecureRequestForm.from_public_token(raw_token)

    assert_equal form.id, found.id
  end

  test 'from_public_token returns nil for blank or unrecognised token' do
    assert_nil MedicalProviderSecureRequestForm.from_public_token('')
    assert_nil MedicalProviderSecureRequestForm.from_public_token(nil)
    assert_nil MedicalProviderSecureRequestForm.from_public_token('not-a-real-token')
  end

  test 'active scope excludes requests expiring at the current instant' do
    travel_to Time.zone.local(2026, 5, 6, 12, 0, 0) do
      form = create(:medical_provider_secure_request_form, expires_at: Time.current)

      assert_predicate form, :expired?
      assert_not_includes MedicalProviderSecureRequestForm.active, form
    end
  end

  test 'open_certification_upload_for_provider matches application provider email and lifecycle' do
    form = create(:medical_provider_secure_request_form)
    create(:medical_provider_secure_request_form,
           :revoked,
           application: form.application,
           provider_email: form.provider_email)
    create(:medical_provider_secure_request_form, provider_email: form.provider_email)

    found = MedicalProviderSecureRequestForm.open_certification_upload_for_provider(
      application_id: form.application_id,
      provider_email: form.provider_email
    )

    assert_equal [form], found.to_a
  end

  test 'mark_submitted! sets status to submitted and records submitted_at' do
    form = create(:medical_provider_secure_request_form)

    freeze_time do
      form.mark_submitted!

      assert_predicate form.reload, :status_submitted?
      assert_in_delta Time.current.to_i, form.submitted_at.to_i, 1
    end
  end

  test 'revoke! sets status to revoked and records revoked_at' do
    form = create(:medical_provider_secure_request_form)

    freeze_time do
      form.revoke!

      assert_predicate form.reload, :status_revoked?
      assert_in_delta Time.current.to_i, form.revoked_at.to_i, 1
    end
  end

  test 'display_status returns submitted revoked expired or active' do
    assert_equal :submitted, build(:medical_provider_secure_request_form, :submitted).display_status
    assert_equal :revoked, build(:medical_provider_secure_request_form, :revoked).display_status
    assert_equal :expired, build(:medical_provider_secure_request_form, :expired).display_status
    assert_equal :active, build(:medical_provider_secure_request_form).display_status
  end
end
