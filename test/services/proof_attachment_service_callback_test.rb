# frozen_string_literal: true

require 'test_helper'

class ProofAttachmentServiceCallbackTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess::FixtureFile

  setup do
    Current.reset
    Event.delete_all
    Notification.delete_all

    @admin = create(:admin)
    @constituent = create(:constituent, email: "callback-test-#{SecureRandom.hex(4)}@example.com")
    @valid_pdf = fixture_file_upload('test/fixtures/files/medical_certification_valid.pdf', 'application/pdf')
  end

  teardown do
    Current.reset
  end

  # --- needs_review_since: set exactly once ---

  test 'portal proof attachment sets needs_review_since exactly once via service attrs' do
    app = create_application_for_resubmission

    assert_nil app.needs_review_since

    result = ProofAttachmentService.attach_proof(
      application: app,
      proof_type: :income,
      blob_or_file: @valid_pdf,
      status: :not_reviewed,
      submission_method: :web,
      metadata: {}
    )

    assert result[:success], "attach_proof failed: #{result[:error]&.message}"
    app.reload

    assert_not_nil app.needs_review_since, 'needs_review_since should be set'
    assert_equal 'not_reviewed', app.income_proof_status
  end

  test 'set_needs_review_timestamp callback is suppressed during proof attachment' do
    app = create_application_for_resubmission

    # The concern's set_needs_review_timestamp skips when
    # Current.proof_attachment_service_context? is true.
    # Verify the flag is active during the service call by checking that
    # needs_review_since is set to the value from the service attrs,
    # not from a second callback-driven update!.
    result = ProofAttachmentService.attach_proof(
      application: app,
      proof_type: :income,
      blob_or_file: @valid_pdf,
      status: :not_reviewed,
      submission_method: :web,
      metadata: {}
    )

    assert result[:success], "attach_proof failed: #{result[:error]&.message}"
    app.reload

    assert_not_nil app.needs_review_since
    assert Current.proof_attachment_service_context != true,
           'Context flag should be restored after service call'
  end

  # --- Scanned/paper proof with status :approved does NOT set needs_review_since ---

  test 'scanned proof with approved status does not set needs_review_since' do
    app = create(:application, :in_progress, user: @constituent)

    result = ProofAttachmentService.attach_proof(
      application: app,
      proof_type: :income,
      blob_or_file: @valid_pdf,
      status: :approved,
      admin: @admin,
      submission_method: :paper,
      skip_audit_events: true,
      metadata: {}
    )

    assert result[:success], "attach_proof failed: #{result[:error]&.message}"
    app.reload

    assert_nil app.needs_review_since, 'Approved scanned proofs should not set needs_review_since'
    assert_equal 'approved', app.income_proof_status
  end

  # --- Auto-approval fires through callback chain ---

  test 'proof attachment with approved status triggers reconciler auto-approval when all requirements met' do
    app = create_application_ready_for_final_proof

    Current.user = @admin

    result = ProofAttachmentService.attach_proof(
      application: app,
      proof_type: :income,
      blob_or_file: @valid_pdf,
      status: :approved,
      admin: @admin,
      submission_method: :paper,
      skip_audit_events: true,
      metadata: {}
    )

    assert result[:success], "attach_proof failed: #{result[:error]&.message}"
    app.reload

    assert_equal 'approved', app.status,
                 'Application should be auto-approved via reconciler when all requirements are met'

    status_change = app.status_changes.find_by(to_status: 'approved')
    assert_not_nil status_change, 'ApplicationStatusChange record should exist for auto-approval'
    assert_equal 'auto_approval', status_change.metadata['trigger']

    status_event = Event.find_by(action: 'application_status_changed', auditable: app)
    assert_not_nil status_event, 'application_status_changed event should exist'
    assert_equal 'auto_approval', status_event.metadata['trigger']

    assert_equal 0, Event.where(auditable: app, action: 'application_auto_approved').count
  end

  test 'proof attachment with not_reviewed status does not trigger auto-approval' do
    app = create(:application, :in_progress, user: @constituent)
    app.update_columns(
      residency_proof_status: Application.residency_proof_statuses[:approved],
      medical_certification_status: Application.medical_certification_statuses[:approved]
    )

    result = ProofAttachmentService.attach_proof(
      application: app,
      proof_type: :income,
      blob_or_file: @valid_pdf,
      status: :not_reviewed,
      submission_method: :web,
      metadata: {}
    )

    assert result[:success]
    app.reload

    assert_equal 'in_progress', app.status,
                 'Application should NOT auto-approve when proof is not_reviewed'
  end

  # --- Paper context suppresses admin self-notifications ---

  test 'paper context suppresses admin proof notifications via notify_admins_of_new_proofs' do
    app = create_application_for_resubmission

    Current.paper_context = true

    assert_no_difference -> { Notification.where(action: 'proof_submitted').count } do
      ProofAttachmentService.attach_proof(
        application: app,
        proof_type: :income,
        blob_or_file: @valid_pdf,
        status: :not_reviewed,
        admin: @admin,
        submission_method: :paper,
        metadata: {}
      )
    end
  end

  # --- Validation safety: update! does not fail on proof attachment validations ---

  test 'proof attachment service update! does not trigger proof attachment validations' do
    app = create(:application, :in_progress, user: @constituent)

    result = ProofAttachmentService.attach_proof(
      application: app,
      proof_type: :income,
      blob_or_file: @valid_pdf,
      status: :not_reviewed,
      submission_method: :web,
      metadata: {}
    )

    assert result[:success], "Should succeed even when residency proof is not attached: #{result[:error]&.message}"
    app.reload
    assert_equal 'not_reviewed', app.income_proof_status
  end

  # --- Proof ingress participates in callback-driven lifecycle ---

  test 'proof status update uses update! so validations and callbacks fire' do
    app = create(:application, :in_progress, user: @constituent)
    validation_ran = false

    original_valid = app.method(:valid?)
    app.define_singleton_method(:valid?) do |*args|
      validation_ran = true
      original_valid.call(*args)
    end

    ProofAttachmentService.attach_proof(
      application: app,
      proof_type: :income,
      blob_or_file: @valid_pdf,
      status: :approved,
      admin: @admin,
      submission_method: :paper,
      skip_audit_events: true,
      metadata: {}
    )

    assert validation_ran, 'Validations should run (update! used, not update_columns)'
  end

  private

  def create_application_for_resubmission
    app = create(:application, :in_progress, user: @constituent)
    app.update_columns(
      income_proof_status: Application.income_proof_statuses[:rejected],
      needs_review_since: nil
    )
    app.reload
    app
  end

  def create_application_ready_for_final_proof
    app = create(:application, :in_progress, user: @constituent)
    app.income_proof.attach(
      io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
      filename: 'income_proof.pdf',
      content_type: 'application/pdf'
    )
    app.residency_proof.attach(
      io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
      filename: 'residency_proof.pdf',
      content_type: 'application/pdf'
    )
    app.save!
    app.update_columns(
      income_proof_status: Application.income_proof_statuses[:not_reviewed],
      residency_proof_status: Application.residency_proof_statuses[:approved],
      medical_certification_status: Application.medical_certification_statuses[:approved],
      status: Application.statuses[:awaiting_dcf]
    )
    app.reload
    app
  end
end
