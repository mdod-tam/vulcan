# frozen_string_literal: true

require 'test_helper'

class SecureFormExpirationRecorderTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
  end

  test 'records expiration events for expired open proof certification and W9 forms' do
    application = create(:application)
    vendor = create(:vendor)
    proof_form = create(:secure_request_form,
                        application: application,
                        recipient: application.user,
                        requested_by: @admin,
                        kind: :income_proof_resubmission,
                        expires_at: 1.hour.ago)
    certification_form = create(:medical_provider_secure_request_form,
                                application: application,
                                requested_by: @admin,
                                expires_at: 1.hour.ago)
    w9_form = create(:vendor_secure_request_form,
                     vendor: vendor,
                     requested_by: @admin,
                     expires_at: 1.hour.ago)

    assert_difference('Event.count', 3) do
      result = SecureFormExpirationRecorder.new.call
      assert_predicate result, :success?
      assert_equal({ proof: 1, certification: 1, w9: 1 }, result.data)
    end

    proof_event = Event.find_by!(auditable: application, action: 'proof_resubmission_request_expired')
    cert_event = Event.find_by!(auditable: application, action: 'cert_upload_request_expired')
    w9_event = Event.find_by!(auditable: vendor, action: 'w9_upload_request_expired')

    assert_equal proof_form.id, proof_event.metadata.fetch('secure_request_form_id')
    assert_equal 'income', proof_event.metadata.fetch('proof_type')
    assert_equal certification_form.id, cert_event.metadata.fetch('medical_provider_secure_request_form_id')
    assert_equal w9_form.id, w9_event.metadata.fetch('vendor_secure_request_form_id')
  end

  test 'does not duplicate expiration events on later runs' do
    application = create(:application)
    create(:secure_request_form,
           application: application,
           recipient: application.user,
           requested_by: @admin,
           kind: :income_proof_resubmission,
           expires_at: 1.hour.ago)

    assert_difference("Event.where(action: 'proof_resubmission_request_expired').count", 1) do
      SecureFormExpirationRecorder.new.call
    end

    assert_no_difference("Event.where(action: 'proof_resubmission_request_expired').count") do
      result = SecureFormExpirationRecorder.new.call
      assert_predicate result, :success?
      assert_equal 0, result.data.fetch(:proof)
    end
  end

  test 'records expiration events with system actor when requester is missing' do
    ensure_system_audit_actor!
    application = create(:application)
    form = create(:secure_request_form,
                  application: application,
                  recipient: application.user,
                  requested_by: nil,
                  kind: :income_proof_resubmission,
                  expires_at: 1.hour.ago)

    assert_difference("Event.where(action: 'proof_resubmission_request_expired').count", 1) do
      result = SecureFormExpirationRecorder.new.call
      assert_predicate result, :success?
      assert_equal 1, result.data.fetch(:proof)
    end

    event = Event.find_by!(auditable: application, action: 'proof_resubmission_request_expired')
    assert_equal form.id, event.metadata.fetch('secure_request_form_id')
    assert_equal User.system_user, event.user
  end

  test 'ignores active submitted and revoked forms' do
    application = create(:application)
    create(:secure_request_form,
           application: application,
           recipient: application.user,
           requested_by: @admin,
           kind: :income_proof_resubmission,
           expires_at: 1.hour.from_now)
    create(:secure_request_form,
           :submitted,
           application: application,
           recipient: application.user,
           requested_by: @admin,
           kind: :residency_proof_resubmission,
           expires_at: 1.hour.ago)
    create(:secure_request_form,
           :revoked,
           application: application,
           recipient: application.user,
           requested_by: @admin,
           kind: :id_proof_resubmission,
           expires_at: 1.hour.ago)

    assert_no_difference('Event.count') do
      result = SecureFormExpirationRecorder.new.call
      assert_predicate result, :success?
    end
  end

  test 'missing system actor leaves an expiration pending until attribution is available' do
    User.where(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL).find_each do |user|
      user.update!(email: "displaced-#{user.id}@example.test")
    end
    form = create(:secure_request_form, kind: :income_proof_resubmission, requested_by: nil, expires_at: 1.hour.ago)

    assert_no_difference ['User.count', 'Event.count'] do
      result = SecureFormExpirationRecorder.new.call
      assert_predicate result, :success?
      assert_equal 0, result.data[:proof]
    end
    assert_nil form.reload.expiration_recorded_at

    actor = ensure_system_audit_actor!
    assert_difference("Event.where(action: 'proof_resubmission_request_expired').count", 1) do
      SecureFormExpirationRecorder.new.call
      SecureFormExpirationRecorder.new.call
    end
    assert_not_nil form.reload.expiration_recorded_at
    assert_equal actor, Event.find_by!(action: 'proof_resubmission_request_expired', auditable: form.application).user
  end

  test 'marks recorded forms so later runs no longer scan them' do
    form = create(:secure_request_form, kind: :income_proof_resubmission, requested_by: @admin, expires_at: 1.hour.ago)

    SecureFormExpirationRecorder.new.call

    assert_not_nil form.reload.expiration_recorded_at
    assert_not_includes SecureRequestForm.expiration_unrecorded, form
  end

  test 'marks a form expired before the marker existed without a second event' do
    form = create(:secure_request_form, kind: :income_proof_resubmission, requested_by: @admin, expires_at: 1.hour.ago)
    AuditEventService.log(action: 'proof_resubmission_request_expired', actor: @admin, auditable: form.application,
                          metadata: { secure_request_form_id: form.id })

    assert_no_difference('Event.count') do
      result = SecureFormExpirationRecorder.new.call
      assert_equal 0, result.data[:proof]
    end
    assert_not_nil form.reload.expiration_recorded_at
  end

  test 'expiration events keep the metadata each form type recorded before' do
    form = create(:medical_provider_secure_request_form, requested_by: @admin, expires_at: 1.hour.ago)

    SecureFormExpirationRecorder.new.call

    event = Event.find_by!(action: 'cert_upload_request_expired')
    assert_equal %w[application_id expires_at medical_provider_secure_request_form_id provider_email provider_name
                    request_batch_id requested_channel],
                 (event.metadata.keys - ['__service_generated']).sort
    assert_equal form.id, event.metadata['medical_provider_secure_request_form_id']
  end
end
