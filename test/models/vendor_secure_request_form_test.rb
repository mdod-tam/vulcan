# frozen_string_literal: true

require 'test_helper'

class VendorSecureRequestFormTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test 'belongs to vendor and snapshots recipient email' do
    form = create(:vendor_secure_request_form)

    assert_equal form.vendor.email, form.recipient_email
  end

  test 'assigns request batch id before validation on create' do
    form = build(:vendor_secure_request_form, request_batch_id: nil)

    assert_nil form.request_batch_id

    form.valid?

    assert form.request_batch_id.present?
  end

  test 'from_public_token resolves the correct record via SHA-256 digest' do
    raw_token = VendorSecureRequestForm.generate_public_token
    form = create(:vendor_secure_request_form, raw_token: raw_token)

    found = VendorSecureRequestForm.from_public_token(raw_token)

    assert_equal form.id, found.id
  end

  test 'from_public_token returns nil for blank or unrecognized token' do
    assert_nil VendorSecureRequestForm.from_public_token('')
    assert_nil VendorSecureRequestForm.from_public_token(nil)
    assert_nil VendorSecureRequestForm.from_public_token('not-a-real-token')
  end

  test 'active scope excludes requests expiring at the current instant' do
    travel_to Time.zone.local(2026, 5, 6, 12, 0, 0) do
      form = create(:vendor_secure_request_form, expires_at: Time.current)

      assert_predicate form, :expired?
      assert_not_includes VendorSecureRequestForm.active, form
    end
  end

  test 'open_w9_upload_for_vendor matches vendor and lifecycle' do
    form = create(:vendor_secure_request_form)
    create(:vendor_secure_request_form, :revoked, vendor: form.vendor, recipient_email: form.recipient_email)
    create(:vendor_secure_request_form)

    found = VendorSecureRequestForm.open_w9_upload_for_vendor(vendor_id: form.vendor_id)

    assert_equal [form], found.to_a
  end

  test 'mark_submitted! sets status to submitted and records submitted_at' do
    form = create(:vendor_secure_request_form)

    freeze_time do
      form.mark_submitted!

      assert_predicate form.reload, :status_submitted?
      assert_in_delta Time.current.to_i, form.submitted_at.to_i, 1
    end
  end

  test 'revoke! sets status to revoked and records revoked_at' do
    form = create(:vendor_secure_request_form)

    freeze_time do
      form.revoke!

      assert_predicate form.reload, :status_revoked?
      assert_in_delta Time.current.to_i, form.revoked_at.to_i, 1
    end
  end

  test 'revoke! records W9 revocation audit metadata' do
    form = create(:vendor_secure_request_form)
    actor = create(:admin)

    assert_difference -> { Event.where(action: 'w9_upload_request_revoked', auditable: form.vendor).count }, 1 do
      form.revoke!(actor: actor, reason: :manual_revocation)
    end

    event = Event.find_by!(action: 'w9_upload_request_revoked', auditable: form.vendor)
    metadata = event.metadata.deep_stringify_keys

    assert_equal actor, event.user
    assert_equal form.id.to_s, metadata['vendor_secure_request_form_id'].to_s
    assert_equal form.vendor_id.to_s, metadata['vendor_id'].to_s
    assert_equal form.request_batch_id, metadata['request_batch_id']
    assert_equal form.recipient_email, metadata['recipient_email']
    assert_equal 'w9_upload', metadata['kind']
    assert_equal 'email', metadata['requested_channel']
    assert_equal 'manual_revocation', metadata['reason']
  end

  test 'display_status returns submitted revoked expired or active' do
    assert_equal :submitted, build(:vendor_secure_request_form, :submitted).display_status
    assert_equal :revoked, build(:vendor_secure_request_form, :revoked).display_status
    assert_equal :expired, build(:vendor_secure_request_form, :expired).display_status
    assert_equal :active, build(:vendor_secure_request_form).display_status
  end
end
