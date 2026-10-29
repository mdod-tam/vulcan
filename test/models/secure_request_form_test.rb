# frozen_string_literal: true

require 'test_helper'

class SecureRequestFormTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  test 'new forms require complete delivery provenance' do
    form = build(:secure_request_form, delivery_owner: nil, delivery_source: nil)

    assert_not form.valid?
    assert_includes form.errors[:delivery_owner], "can't be blank"
    assert_includes form.errors[:delivery_source], "can't be blank"
  end

  test 'delivery owner and source must remain paired' do
    form = create(:secure_request_form)

    form.delivery_source = nil

    assert_not form.valid?
    assert_includes form.errors[:base], 'Delivery owner and delivery source must both be present or both be absent'
  end

  test 'historical ownerless forms can complete their existing lifecycle' do
    form = create(:secure_request_form)
    form.update_columns(delivery_owner_id: nil, delivery_source: nil)

    assert_not_predicate form.reload, :delivery_provenance?

    form.mark_submitted!

    assert_predicate form.reload, :submitted?
  end

  test 'historical ownerless forms use the logical recipient locale' do
    recipient = create(:constituent, locale: 'es')
    form = create(:secure_request_form, recipient: recipient)
    form.update_columns(delivery_owner_id: nil, delivery_source: nil)

    assert_equal :es, form.reload.delivery_locale
  end

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

  # Token digests and resolution

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

  # Lifecycle predicates: revoked?

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

  # Lifecycle predicates: submitted?

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

  # Lifecycle mutations: mark_submitted! and revoke!

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

  # display_status derivation

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

  # active_for_public_use? and active?

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

  # Forms in one batch share request_batch_id. Each form has independent revocation.

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

  test 'revoke! does not overwrite a submission that committed first' do
    admin = create(:admin)
    form = create(:secure_request_form)
    # Another request submits the form after this copy was loaded.
    SecureRequestForm.where(id: form.id).update_all(status: SecureRequestForm.statuses[:submitted], submitted_at: Time.current)

    assert_no_difference -> { Event.where(action: 'provider_info_request_revoked').count } do
      assert_not form.revoke!(actor: admin, reason: :manual_revocation)
    end
    assert_predicate form.reload, :status_submitted?
    assert_nil form.revoked_at
  end

  test 'revoke! revokes an open form and records one audit event' do
    admin = create(:admin)
    form = create(:secure_request_form, kind: :income_proof_resubmission)

    assert_difference -> { Event.where(action: 'proof_resubmission_request_revoked').count }, 1 do
      assert form.revoke!(actor: admin, reason: :manual_revocation)
    end
    event = Event.where(action: 'proof_resubmission_request_revoked').last
    assert_equal 'income', event.metadata['proof_type']
    assert_equal 'manual_revocation', event.metadata['reason']
    assert_not form.revoke!(actor: admin), 'a second revoke is a no-op'
  end

  # Certification upload links go to the application's certifying provider, who is not a user.

  test 'a certification link is addressed to the provider and snapshots the provider on file' do
    application = create(:application, certifying_professional_name: 'Dr. Provider', certifying_professional_email: 'provider@example.test')
    form = create(:certification_upload_form, application: application)

    assert_nil form.recipient
    assert_nil form.delivery_owner
    assert_nil form.delivery_source
    assert_predicate form, :recipient_role_provider?
    assert_equal 'provider@example.test', form.recipient_email
    assert_equal 'Dr. Provider', form.recipient_name
  end

  test 'a certification link uses the default locale whatever the applicant speaks' do
    applicant = create(:constituent, locale: 'es')
    application = create(:application, user: applicant)

    assert_equal I18n.default_locale, create(:certification_upload_form, application: application).delivery_locale
  end

  test 'a certification link needs the provider email' do
    form = build(:certification_upload_form, recipient_email: nil)

    assert_not form.valid?
    assert_includes form.errors[:recipient_email], "can't be blank"
  end

  test 'a certification link refuses a user recipient and a delivery owner' do
    user = create(:constituent)

    with_recipient = build(:certification_upload_form, recipient: user)
    with_owner = build(:certification_upload_form, delivery_owner: user, delivery_source: :constituent)

    [with_recipient, with_owner].each do |form|
      assert_not form.valid?
      assert_includes form.errors[:base], 'A certification link has no user recipient or delivery owner'
    end
  end

  test 'a proof or provider-info link still needs a recipient and a delivery owner' do
    %i[provider_info_request id_proof_resubmission].each do |kind|
      form = build(:secure_request_form, kind: kind, recipient: nil, recipient_email: 'x@example.test', recipient_phone: nil, delivery_owner: nil, delivery_source: nil)

      assert_not form.valid?, kind
      assert_includes form.errors[:recipient], 'must exist', kind
      assert_includes form.errors[:delivery_owner], "can't be blank", kind
    end
  end

  test 'the database keeps a certification link free of users and every other link addressed to one' do
    user = create(:constituent)
    provider_with_user = build(:certification_upload_form, recipient: user)
    user_link_without_user = build(:secure_request_form, recipient: nil, recipient_email: 'x@example.test', recipient_phone: nil)

    [provider_with_user, user_link_without_user].each do |form|
      assert_raises(ActiveRecord::StatementInvalid) { form.save!(validate: false) }
    end
  end

  test 'the database allows one active certification link per application' do
    application = create(:application, certifying_professional_email: 'provider@example.test')
    create(:certification_upload_form, application: application)

    assert_raises(ActiveRecord::RecordNotUnique) do
      build(:certification_upload_form, application: application, recipient_email: 'second@example.test').save!(validate: false)
    end
    assert_nothing_raised do
      create(:certification_upload_form, :revoked, application: application)
      create(:certification_upload_form, :submitted, application: create(:application, certifying_professional_email: 'provider@example.test'))
    end
  end

  test 'the certification scope is the only way a certification token resolves' do
    raw_token = SecureRequestForm.generate_public_token
    form = create(:certification_upload_form, raw_token: raw_token)
    proof_token = SecureRequestForm.generate_public_token
    create(:secure_request_form, kind: :income_proof_resubmission, raw_token: proof_token)

    assert_equal form, SecureRequestForm.certification_upload.from_public_token(raw_token)
    assert_nil SecureRequestForm.certification_upload.from_public_token(proof_token),
               'a proof token must resolve to nothing in the certification scope'
  end

  test 'open_certification_upload_for_application matches the application, kind, and lifecycle' do
    form = create(:certification_upload_form)
    create(:certification_upload_form, :revoked, application: form.application)
    create(:certification_upload_form)
    create(:secure_request_form, application: form.application, kind: :provider_info_request)

    found = SecureRequestForm.open_certification_upload_for_application(application_id: form.application_id)

    assert_equal [form], found.to_a
  end

  test 'certification links name their own audit actions and keep the provider in their metadata' do
    form = create(:certification_upload_form)

    assert_equal 'cert_upload_request_revoked', form.revocation_audit_action
    assert_equal 'cert_upload_request_expired', form.expiration_audit_action
    assert_equal({ application_id: form.application_id, secure_request_form_id: form.id, request_batch_id: form.request_batch_id,
                   provider_name: form.recipient_name, provider_email: form.recipient_email, requested_channel: 'email' },
                 form.audit_metadata)
  end

  test 'an application lists user-recipient links and certification links separately' do
    application = create(:application)
    user_link = create(:secure_request_form, application: application)
    certification_link = create(:certification_upload_form, application: application)

    assert_equal [user_link], application.secure_request_forms.to_a
    assert_equal [certification_link], application.certification_upload_forms.to_a
    assert_empty SecureRequestForm.with_incomplete_delivery_provenance.where(id: certification_link.id)
  end

  test 'destroying an application removes both kinds of link' do
    application = create(:application)
    create(:secure_request_form, application: application)
    create(:certification_upload_form, application: application)

    assert_difference 'SecureRequestForm.count', -2 do
      application.destroy!
    end
  end
end
