# frozen_string_literal: true

require 'test_helper'

class SecureRequestFormTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test 'active scope does not add a provider info kind predicate' do
    sql = SecureRequestForm.provider_info.active.to_sql

    assert_equal 1, sql.scan('"secure_request_forms"."kind"').size
  end

  test 'active scope excludes requests expiring at the current instant' do
    travel_to Time.zone.local(2026, 5, 5, 12, 0, 0) do
      secure_request_form = create(:secure_request_form, expires_at: Time.current)

      assert_predicate secure_request_form, :expired?
      assert_not_includes SecureRequestForm.active, secure_request_form
    end
  end

  test 'assigns request batch id before validation on create' do
    secure_request_form = build(:secure_request_form, request_batch_id: nil)

    assert_nil secure_request_form.request_batch_id

    secure_request_form.valid?

    assert secure_request_form.request_batch_id.present?
  end

  test 'active predicate reflects public usability' do
    secure_request_form = build(:secure_request_form)

    assert_predicate secure_request_form, :active?

    secure_request_form.expires_at = 1.minute.ago

    assert_not secure_request_form.active?
  end

  test 'proof resubmission scopes isolate proof kinds' do
    id_form = create(:secure_request_form, kind: :id_proof_resubmission)
    residency_form = create(:secure_request_form, kind: :residency_proof_resubmission)
    income_form = create(:secure_request_form, kind: :income_proof_resubmission)
    provider_form = create(:secure_request_form)

    assert_includes SecureRequestForm.proof_resubmission, id_form
    assert_includes SecureRequestForm.proof_resubmission, residency_form
    assert_includes SecureRequestForm.proof_resubmission, income_form
    assert_not_includes SecureRequestForm.proof_resubmission, provider_form

    local_forms = SecureRequestForm.where(id: [id_form.id, residency_form.id, income_form.id, provider_form.id])
    assert_equal [id_form], local_forms.id_proof.to_a
    assert_equal [residency_form], local_forms.residency_proof.to_a
    assert_equal [income_form], local_forms.income_proof.to_a
  end

  test 'open proof recipient scopes match kind recipient and lifecycle' do
    form = create(:secure_request_form, kind: :income_proof_resubmission)
    create(:secure_request_form, kind: :income_proof_resubmission, application: form.application, recipient: form.recipient, status: :revoked, revoked_at: Time.current)
    create(:secure_request_form, kind: :residency_proof_resubmission, application: form.application, recipient: form.recipient)

    found = SecureRequestForm.open_income_proof_for_recipient(
      application_id: form.application_id,
      recipient_id: form.recipient_id
    )

    assert_equal [form], found.to_a
  end

  # -----------------------------------------------------------------------
  # Token digesting and resolution
  # -----------------------------------------------------------------------

  test 'from_public_token resolves the correct record via SHA-256 digest' do
    raw_token = SecureRequestForm.generate_public_token
    form = create(:secure_request_form, raw_token: raw_token)

    found = SecureRequestForm.from_public_token(raw_token)

    assert_equal form.id, found.id
  end

  test 'from_public_token returns nil for a blank token' do
    assert_nil SecureRequestForm.from_public_token('')
    assert_nil SecureRequestForm.from_public_token(nil)
  end

  test 'from_public_token returns nil for an unrecognised token' do
    assert_nil SecureRequestForm.from_public_token('completely-unregistered-token-xyz')
  end

  test 'digest_public_token produces a different digest for each unique token' do
    token_a = SecureRequestForm.generate_public_token
    token_b = SecureRequestForm.generate_public_token

    assert_not_equal token_a, token_b
    assert_not_equal SecureRequestForm.digest_public_token(token_a),
                     SecureRequestForm.digest_public_token(token_b)
  end

  # -----------------------------------------------------------------------
  # Lifecycle predicates: revoked?
  # -----------------------------------------------------------------------

  test 'revoked? is true when status is revoked' do
    form = build(:secure_request_form, :revoked)

    assert_predicate form, :revoked?
  end

  test 'revoked? is true when revoked_at is set even if status has not been updated' do
    form = build(:secure_request_form, status: :sent, revoked_at: 1.minute.ago)

    assert_predicate form, :revoked?
  end

  test 'revoked? is false for a newly sent form' do
    form = build(:secure_request_form)

    assert_not_predicate form, :revoked?
  end

  # -----------------------------------------------------------------------
  # Lifecycle predicates: submitted?
  # -----------------------------------------------------------------------

  test 'submitted? is true when status is submitted' do
    form = build(:secure_request_form, :submitted)

    assert_predicate form, :submitted?
  end

  test 'submitted? is true when submitted_at is set even if status has not been updated' do
    form = build(:secure_request_form, status: :sent, submitted_at: 1.minute.ago)

    assert_predicate form, :submitted?
  end

  test 'submitted? is false for a newly sent form' do
    form = build(:secure_request_form)

    assert_not_predicate form, :submitted?
  end

  # -----------------------------------------------------------------------
  # Lifecycle mutations: mark_submitted! and revoke!
  # -----------------------------------------------------------------------

  test 'mark_submitted! sets status to submitted and records submitted_at' do
    form = create(:secure_request_form)

    freeze_time do
      form.mark_submitted!

      assert_predicate form.reload, :status_submitted?
      assert_in_delta Time.current.to_i, form.submitted_at.to_i, 1
    end
  end

  test 'revoke! sets status to revoked and records revoked_at' do
    form = create(:secure_request_form)

    freeze_time do
      form.revoke!

      assert_predicate form.reload, :status_revoked?
      assert_in_delta Time.current.to_i, form.revoked_at.to_i, 1
    end
  end

  # -----------------------------------------------------------------------
  # display_status derivation
  # -----------------------------------------------------------------------

  test 'display_status returns :submitted for a submitted form' do
    form = build(:secure_request_form, :submitted)

    assert_equal :submitted, form.display_status
  end

  test 'display_status returns :revoked for a revoked form' do
    form = build(:secure_request_form, :revoked)

    assert_equal :revoked, form.display_status
  end

  test 'display_status returns :expired for an expired form that is not revoked or submitted' do
    form = build(:secure_request_form, :expired)

    assert_equal :expired, form.display_status
  end

  test 'display_status returns :active for a sent form within its expiry window' do
    form = build(:secure_request_form)

    assert_equal :active, form.display_status
  end

  # -----------------------------------------------------------------------
  # active_for_public_use? vs active?
  # -----------------------------------------------------------------------

  test 'active_for_public_use? and active? agree for a newly sent form' do
    form = build(:secure_request_form)

    assert_predicate form, :active_for_public_use?
    assert_predicate form, :active?
  end

  test 'active_for_public_use? is false when the form is revoked' do
    form = build(:secure_request_form, :revoked)

    assert_not_predicate form, :active_for_public_use?
  end

  test 'active_for_public_use? is false when the form is submitted' do
    form = build(:secure_request_form, :submitted)

    assert_not_predicate form, :active_for_public_use?
  end

  test 'active_for_public_use? is false when the form is expired' do
    form = build(:secure_request_form, :expired)

    assert_not_predicate form, :active_for_public_use?
  end

  # -----------------------------------------------------------------------
  # Multi-recipient batch: shared request_batch_id, independent revocation
  # -----------------------------------------------------------------------

  test 'revoking one form does not revoke a sibling form from the same batch' do
    application = create(:application)
    guardian = create(:constituent)
    batch_id = SecureRandom.uuid

    first_form = create(:secure_request_form, application: application,
                                              recipient: application.user,
                                              request_batch_id: batch_id)
    sibling_form = create(:secure_request_form, application: application,
                                                recipient: guardian,
                                                request_batch_id: batch_id)

    first_form.revoke!

    assert_predicate first_form.reload, :revoked?
    assert_not_predicate sibling_form.reload, :revoked?
    assert_predicate sibling_form.reload, :active?
  end
end
