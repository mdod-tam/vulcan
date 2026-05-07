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
end
