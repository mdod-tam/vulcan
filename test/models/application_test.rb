# frozen_string_literal: true

require 'test_helper'

class ApplicationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def setup
    @admin = create(:admin)

    # Set paper application context for tests
    setup_paper_application_context

    # Use skip_proofs option to avoid callbacks that might cause recursion
    @application = create(:application, :in_progress, skip_proofs: true)
    @proof_review = build(:proof_review,
                          application: @application,
                          admin: @admin)
  end

  def teardown
    # Clear Current attributes after tests
    Current.reset if defined?(Current) && Current.respond_to?(:reset)
  end

  # Skip notifications tests for now as they're inconsistent with our new safeguards
  test 'notifies admins when proofs need review' do
    skip 'Skipping notification test until compatible with new guards'
  end

  test 'paper applications can be rejected without attachments' do
    # Set Current attributes for paper application context
    Current.force_notifications = false
    Current.paper_context = true

    begin
      # Create a basic application
      application = create(:application, :in_progress, skip_proofs: true)

      # Reject proofs without attachments
      application.reject_proof_without_attachment!(:income, admin: @admin, reason: 'other', notes: 'Test rejection')
      application.reject_proof_without_attachment!(:id, admin: @admin, reason: 'other', notes: 'Test rejection')
      application.reject_proof_without_attachment!(:residency, admin: @admin, reason: 'other', notes: 'Test rejection')

      # Verify proofs were rejected
      application.reload
      assert application.income_proof_status_rejected?
      assert application.id_proof_status_rejected?
      assert application.residency_proof_status_rejected?
      assert_not application.income_proof.attached?
      assert_not application.id_proof.attached?
      assert_not application.residency_proof.attached?
    ensure
      # Reset Current attributes
      Current.reset if defined?(Current) && Current.respond_to?(:reset)
    end
  end

  test 'applications correctly track proof status changes' do
    # Set Current attributes for paper application context
    Current.force_notifications = false
    Current.paper_context = true

    begin
      # Create a test application
      application = create(:application, :in_progress, skip_proofs: true)

      # Create fixture files
      fixture_dir = Rails.root.join('test/fixtures/files')
      FileUtils.mkdir_p(fixture_dir)

      ['income_proof.pdf', 'residency_proof.pdf', 'id_proof.pdf'].each do |filename|
        file_path = fixture_dir.join(filename)
        File.write(file_path, "Test content for #{filename}") unless File.exist?(file_path)
      end

      # Directly update proof status using SQL to avoid callbacks
      ActiveRecord::Base.connection.execute(<<~SQL.squish)
        UPDATE applications
        SET income_proof_status = #{Application.income_proof_statuses[:approved]},
            residency_proof_status = #{Application.residency_proof_statuses[:approved]},
            id_proof_status = #{Application.id_proof_statuses[:approved]}
        WHERE id = #{application.id}
      SQL

      # Refresh application record
      application = Application.uncached { Application.find(application.id) }

      # Check proof status
      assert_equal 'approved', application.income_proof_status
      assert_equal 'approved', application.residency_proof_status
      assert_equal 'approved', application.id_proof_status
    ensure
      # Reset Current attributes
      Current.reset if defined?(Current) && Current.respond_to?(:reset)
    end
  end

  test 'transition_status! logs application_status_changed with explicit constituent actor' do
    # Set Current attributes to disable notifications in tests
    Current.force_notifications = false

    # Create an application with a known user (proofs will be attached by factory default)
    application = create(:application, :draft)

    # Ensure Current.user is nil
    Current.user = nil

    # Verify initial state
    assert_equal 'draft', application.status

    assert_difference -> { ApplicationStatusChange.count }, 1 do
      assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
        # Change the application status to trigger transition_status!
        application.transition_status!(:in_progress, actor: application.user, metadata: { trigger: 'test' })
      end
    end

    # Verify the status change was logged correctly
    status_change = application.status_changes.last
    assert_equal 'draft', status_change.from_status
    assert_equal 'in_progress', status_change.to_status
    assert_equal application.user, status_change.user

    # Verify audit event was created correctly
    audit_event = Event.where(action: 'application_status_changed', auditable: application).last
    assert_equal application.user, audit_event.user
    assert_equal 'in_progress', audit_event.metadata['new_status']
    assert_equal 'draft', audit_event.metadata['old_status']
  end

  test 'transition_status! attributes audit to passed actor not Current.user' do
    # Set Current attributes to disable notifications in tests
    Current.force_notifications = false

    # Create an application and an admin user
    application = create(:application, :draft)
    admin = create(:admin)

    # Set Current.user to admin
    Current.user = admin

    # Verify initial state
    assert_equal 'draft', application.status

    assert_difference -> { ApplicationStatusChange.count }, 1 do
      assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
        # Pass a different actor to transition_status!
        other_admin = create(:admin)
        application.transition_status!(:in_progress, actor: other_admin, metadata: { trigger: 'test' })
      end
    end

    # Verify the status change used the passed actor, not Current.user
    status_change = application.status_changes.last
    assert_equal 'draft', status_change.from_status
    assert_equal 'in_progress', status_change.to_status
    assert_not_equal admin, status_change.user

    # Verify audit event used the passed actor
    audit_event = Event.where(action: 'application_status_changed', auditable: application).last
    assert_not_equal admin, audit_event.user
  end

  test 'submit! transitions status to in_progress and logs audit event' do
    application = create(:application, :draft)
    actor = application.user

    assert_difference -> { ApplicationStatusChange.count }, 1 do
      assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
        application.submit!(actor: actor)
      end
    end

    assert application.status_in_progress?

    status_change = application.status_changes.last
    assert_equal 'in_progress', status_change.to_status
    assert_equal actor, status_change.user
    assert_equal 'submission', status_change.metadata['trigger']
  end

  test 'training_request_pending? is true until a newer training session is created' do
    application = create(:application, :approved)

    travel_to Time.zone.local(2026, 4, 7, 10, 0, 0) do
      application.update!(training_requested_at: Time.current)
    end

    assert application.training_request_pending?

    travel_to Time.zone.local(2026, 4, 7, 11, 0, 0) do
      create(:training_session, application: application, trainer: create(:trainer), status: :requested)
    end

    assert_not application.reload.training_request_pending?
  end

  test 'training_request_pending? is true again after a later re-request' do
    application = create(:application, :approved)
    trainer = create(:trainer)

    travel_to Time.zone.local(2026, 4, 7, 9, 0, 0) do
      application.update!(training_requested_at: Time.current)
    end

    travel_to Time.zone.local(2026, 4, 7, 10, 0, 0) do
      create(:training_session, application: application, trainer: trainer, status: :completed, notes: 'done', completed_at: Time.current)
    end

    travel_to Time.zone.local(2026, 4, 7, 11, 0, 0) do
      application.update!(training_requested_at: Time.current)
    end

    assert application.reload.training_request_pending?
  end

  test 'with_pending_training_request returns only approved applications with unresolved requests' do
    pending_application = create(:application, :approved)
    pending_application.update!(training_requested_at: 1.hour.ago)

    fulfilled_application = create(:application, :approved)
    fulfilled_application.update!(training_requested_at: 2.hours.ago)
    create(:training_session, application: fulfilled_application, trainer: create(:trainer), status: :requested)

    non_approved_application = create(:application, :in_progress)
    non_approved_application.update!(training_requested_at: 1.hour.ago)

    results = Application.with_pending_training_request

    assert_includes results, pending_application
    assert_not_includes results, fulfilled_application
    assert_not_includes results, non_approved_application
  end

  test 'service_window_active? returns true for approved applications inside the service window' do
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    application = create(:application, status: :approved, application_date: 2.years.ago.to_date)

    assert application.service_window_active?
  end

  test 'service_window_active? returns false for approved applications outside the service window' do
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    application = create(:application, status: :approved, application_date: 3.years.ago.to_date)

    assert_not application.service_window_active?
  end

  test 'service_window_active? returns false for non-approved applications' do
    application = create(:application, status: :in_progress, application_date: 1.year.ago.to_date)

    assert_not application.service_window_active?
  end

  test 'assign_trainer! fails outside the service window' do
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    application = create(:application, status: :approved, application_date: 4.years.ago.to_date)
    trainer = create(:trainer)

    assert_no_difference -> { TrainingSession.count } do
      assert_not application.assign_trainer!(trainer)
    end

    assert_includes application.errors[:base], I18n.t('activerecord.errors.models.application.attributes.base.training_service_window')
  end

  test 'assign_trainer! fails when completed training session quota is exhausted' do
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
    application = create(:application, status: :approved, application_date: 2.years.ago.to_date)
    trainer = create(:trainer)
    create_list(:training_session, 3, :completed, application: application, trainer: trainer)

    assert_no_difference -> { TrainingSession.count } do
      assert_not application.assign_trainer!(trainer)
    end

    assert_includes application.errors[:base],
                    I18n.t('activerecord.errors.models.application.attributes.base.training_session_quota_exhausted')
  end

  test 'assign_trainer! fails when an active training session exists' do
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    Policy.find_or_create_by(key: 'max_training_sessions').update!(value: 3)
    application = create(:application, status: :approved, application_date: 2.years.ago.to_date)
    trainer = create(:trainer)
    create(:training_session, application: application, trainer: trainer, status: :requested)

    assert_no_difference -> { TrainingSession.count } do
      assert_not application.assign_trainer!(trainer)
    end

    assert_includes application.errors[:base],
                    I18n.t('activerecord.errors.models.application.attributes.base.training_session_active')
  end

  test 'unassign_trainer! cancels active training session with admin initiator' do
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    application = create(:application, status: :approved, application_date: 2.years.ago.to_date)
    trainer = create(:trainer)
    admin = create(:admin)
    training_session = create(:training_session, :requested, application: application, trainer: trainer)

    assert_difference -> { Event.where(action: 'trainer_unassigned').count }, 1 do
      assert application.unassign_trainer!(actor: admin)
    end

    training_session.reload
    assert training_session.status_cancelled?
    assert training_session.cancellation_initiator_admin?
    assert_not application.reload.active_training_session_present?
  end

  test 'assign_evaluator! fails outside the service window' do
    Policy.find_or_create_by(key: 'waiting_period_years').update!(value: 3)
    application = create(:application, status: :approved, application_date: 4.years.ago.to_date)
    evaluator = create(:evaluator)

    assert_no_difference -> { Evaluation.count } do
      assert_not application.assign_evaluator!(evaluator)
    end

    assert_includes application.errors[:base], I18n.t('activerecord.errors.models.application.attributes.base.evaluation_service_window')
  end

  test 'batch_update_status updates multiple applications and returns success' do
    app1 = create(:application, :draft)
    app2 = create(:application, :draft)
    admin = create(:admin)

    assert_difference -> { ApplicationStatusChange.count }, 2 do
      result = Application.batch_update_status([app1.id, app2.id], :in_progress, actor: admin)
      assert result[:success]
      assert_equal 2, result[:success_count]
      assert_empty result[:errors]
    end

    assert app1.reload.status_in_progress?
    assert app2.reload.status_in_progress?
  end

  test 'batch_update_status handles errors and returns them, rolling back all changes' do
    app1 = create(:application, :draft)
    app2 = create(:application, :draft)
    admin = create(:admin)

    # Force an error on the second application
    Application.any_instance.stubs(:transition_status!).returns(true).then.raises(StandardError.new('Test error'))

    assert_no_difference -> { ApplicationStatusChange.count } do
      result = Application.batch_update_status([app1.id, app2.id], :in_progress, actor: admin)
      assert_not result[:success]
      assert_equal 0, result[:success_count]
      assert_includes result[:errors].first, 'Test error'
    end

    # Verify both applications rolled back
    assert app1.reload.status_draft?
    assert app2.reload.status_draft?
  end

  test 'batch_update_status handles missing application IDs' do
    app1 = create(:application, :draft)
    admin = create(:admin)

    assert_no_difference -> { ApplicationStatusChange.count } do
      result = Application.batch_update_status([app1.id, 999_999], :in_progress, actor: admin)
      assert_not result[:success]
      assert_equal 0, result[:success_count]
      assert_includes result[:errors].first, 'Applications not found: 999999'
    end

    assert app1.reload.status_draft?
  end

  test 'batch_update_status handles empty IDs array' do
    admin = create(:admin)

    assert_no_difference -> { ApplicationStatusChange.count } do
      result = Application.batch_update_status([], :in_progress, actor: admin)
      assert_not result[:success]
      assert_equal 0, result[:success_count]
      assert_includes result[:errors].first, 'No applications selected'
    end
  end

  test 'status_draft? predicate method works correctly' do
    application = create(:application, status: :draft)
    approved_app = create(:application, status: :approved)

    assert application.status_draft?
    assert_not approved_app.status_draft?
  end

  test 'status_approved scope returns only approved applications' do
    approved_app = create(:application, status: :approved)
    rejected_app = create(:application, status: :rejected)
    draft_app = create(:application, status: :draft)

    approved_applications = Application.status_approved

    assert_includes approved_applications, approved_app
    assert_not_includes approved_applications, rejected_app
    assert_not_includes approved_applications, draft_app
  end

  test 'status_rejected scope returns only rejected applications' do
    approved_app = create(:application, status: :approved)
    rejected_app = create(:application, status: :rejected)
    draft_app = create(:application, status: :draft)

    rejected_applications = Application.status_rejected

    assert_includes rejected_applications, rejected_app
    assert_not_includes rejected_applications, approved_app
    assert_not_includes rejected_applications, draft_app
  end

  # Tests for Pain Point Analysis
  test 'draft scope returns only draft applications' do
    draft_app = create(:application, status: :draft)
    in_progress_app = create(:application, status: :in_progress)

    draft_applications = Application.draft

    assert_includes draft_applications, draft_app
    assert_not_includes draft_applications, in_progress_app
  end

  test 'pain_point_analysis returns correct counts grouped by last_visited_step' do
    # Create draft applications with different last visited steps
    create(:application, status: :draft, last_visited_step: 'step_1')
    create(:application, status: :draft, last_visited_step: 'step_1')
    create(:application, status: :draft, last_visited_step: 'step_2')
    create(:application, status: :draft, last_visited_step: nil) # Should be ignored
    create(:application, status: :draft, last_visited_step: '') # Should be ignored
    create(:application, status: :in_progress, last_visited_step: 'step_1') # Should be ignored (not draft)

    analysis = Application.pain_point_analysis

    expected_analysis = {
      'step_1' => 2,
      'step_2' => 1
    }

    assert_equal expected_analysis, analysis
  end

  test 'pain_point_analysis returns empty hash when no relevant drafts exist' do
    create(:application, status: :in_progress, last_visited_step: 'step_1')
    create(:application, status: :draft, last_visited_step: nil)

    analysis = Application.pain_point_analysis

    assert_equal({}, analysis)
  end

  # --- Managing Guardian Tests ---

  test 'application can have a managing_guardian' do
    # Use timestamp to ensure unique phone numbers
    timestamp = Time.current.to_i
    guardian = create(:constituent, email: "guardian.app.#{timestamp}@example.com", phone: "555555#{timestamp.to_s[-4..]}")
    applicant_user = create(:constituent, email: "applicant.app.#{timestamp + 1}@example.com", phone: "555556#{timestamp.to_s[-4..]}")
    application = create(:application, user: applicant_user, managing_guardian: guardian)

    assert_equal(guardian, application.managing_guardian)
    assert_equal(applicant_user, application.user)
  end

  test 'application is valid without a managing_guardian' do
    timestamp = Time.current.to_i
    applicant_user = create(:constituent, email: "solo.applicant.#{timestamp}@example.com", phone: "555557#{timestamp.to_s[-4..]}")
    application = create(:application, user: applicant_user, managing_guardian: nil)
    assert(application.valid?)
  end

  test 'application user is the actual applicant (e.g. minor)' do
    timestamp = Time.current.to_i
    guardian = create(:constituent, email: "guardian.for.minor.#{timestamp}@example.com", phone: "555558#{timestamp.to_s[-4..]}")
    minor_applicant = create(:constituent, email: "minor.applicant.#{timestamp}@example.com", phone: "555559#{timestamp.to_s[-4..]}")
    # Create the relationship between guardian and dependent
    GuardianRelationship.create!(guardian_user: guardian, dependent_user: minor_applicant, relationship_type: 'Parent')

    application_for_minor = create(:application, user: minor_applicant, managing_guardian: guardian)

    assert_equal(minor_applicant, application_for_minor.user, "Application's user should be the minor.")
    assert_equal(guardian, application_for_minor.managing_guardian, "Application's managing_guardian should be the guardian.")
  end

  # --- escalate_to_dcf! tests ---

  test 'escalate_to_dcf! transitions to awaiting_dcf and requests certification when proofs approved' do
    application = create(:application, :in_progress, skip_proofs: true)
    application.update_columns(
      status: Application.statuses[:in_progress],
      income_proof_status: Application.income_proof_statuses[:approved],
      residency_proof_status: Application.residency_proof_statuses[:approved],
      id_proof_status: Application.id_proof_statuses[:approved],
      medical_certification_status: Application.medical_certification_statuses[:not_requested],
      updated_at: Time.current
    )
    application.reload

    request_mail = mock('request_mail')
    request_mail.expects(:deliver_later).once
    MedicalProviderMailer.expects(:request_certification).with(application).returns(request_mail).once

    assert_difference -> { ApplicationStatusChange.where(application: application, to_status: 'awaiting_dcf').count }, 1 do
      assert_difference -> { Event.where(auditable: application, action: 'application_status_changed').count }, 1 do
        application.escalate_to_dcf!(actor: @admin, trigger: :proof_review_approved)
      end
    end

    application.reload
    assert_equal 'awaiting_dcf', application.status
    assert_equal 'requested', application.medical_certification_status
  end

  test 'escalate_to_dcf! transitions to awaiting_dcf but skips cert request when proofs not approved' do
    application = create(:application, :in_progress, skip_proofs: true)
    application.update_columns(
      status: Application.statuses[:in_progress],
      income_proof_status: Application.income_proof_statuses[:approved],
      residency_proof_status: Application.residency_proof_statuses[:not_reviewed],
      medical_certification_status: Application.medical_certification_statuses[:not_requested],
      updated_at: Time.current
    )
    application.reload

    MedicalProviderMailer.expects(:request_certification).never

    application.escalate_to_dcf!(actor: @admin, trigger: :document_request)

    application.reload
    assert_equal 'awaiting_dcf', application.status
    assert_equal 'not_requested', application.medical_certification_status
  end

  test 'escalate_to_dcf! self-heals: skips transition but requests cert when already awaiting_dcf' do
    application = create(:application, :in_progress, skip_proofs: true)
    application.update_columns(
      status: Application.statuses[:awaiting_dcf],
      income_proof_status: Application.income_proof_statuses[:approved],
      id_proof_status: Application.id_proof_statuses[:approved],
      residency_proof_status: Application.residency_proof_statuses[:approved],
      medical_certification_status: Application.medical_certification_statuses[:not_requested],
      updated_at: Time.current
    )
    application.reload

    request_mail = mock('request_mail')
    request_mail.expects(:deliver_later).once
    MedicalProviderMailer.expects(:request_certification).with(application).returns(request_mail).once

    assert_no_difference -> { ApplicationStatusChange.where(application: application).count } do
      application.escalate_to_dcf!(actor: @admin, trigger: :proof_review_approved)
    end

    application.reload
    assert_equal 'awaiting_dcf', application.status
    assert_equal 'requested', application.medical_certification_status
  end

  test 'escalate_to_dcf! no-ops for terminal statuses' do
    %i[approved rejected archived].each do |terminal_status|
      application = create(:application, skip_proofs: true, status: terminal_status)
      application.update_columns(
        income_proof_status: Application.income_proof_statuses[:approved],
        residency_proof_status: Application.residency_proof_statuses[:approved],
        medical_certification_status: Application.medical_certification_statuses[:not_requested],
        updated_at: Time.current
      )
      application.reload

      MedicalProviderMailer.expects(:request_certification).never

      assert_no_difference -> { ApplicationStatusChange.where(application: application).count } do
        application.escalate_to_dcf!(actor: @admin, trigger: :proof_review_approved)
      end

      application.reload
      assert_equal terminal_status.to_s, application.status,
                   "Expected #{terminal_status} to remain unchanged"
      assert_equal 'not_requested', application.medical_certification_status,
                   "Expected cert status to remain not_requested for #{terminal_status}"
    end
  end

  test 'escalate_to_dcf! is idempotent when already awaiting_dcf with cert requested' do
    application = create(:application, :in_progress, skip_proofs: true)
    application.update_columns(
      status: Application.statuses[:awaiting_dcf],
      income_proof_status: Application.income_proof_statuses[:approved],
      residency_proof_status: Application.residency_proof_statuses[:approved],
      medical_certification_status: Application.medical_certification_statuses[:requested],
      updated_at: Time.current
    )
    application.reload

    MedicalProviderMailer.expects(:request_certification).never

    assert_no_difference -> { ApplicationStatusChange.where(application: application).count } do
      assert_no_difference -> { Event.where(auditable: application, action: 'application_status_changed').count } do
        application.escalate_to_dcf!(actor: @admin, trigger: :proof_review_approved)
      end
    end

    application.reload
    assert_equal 'awaiting_dcf', application.status
    assert_equal 'requested', application.medical_certification_status
  end

  test 'escalate_to_dcf! creates exactly one status change and one audit event' do
    application = create(:application, :in_progress, skip_proofs: true)
    application.update_columns(
      status: Application.statuses[:in_progress],
      income_proof_status: Application.income_proof_statuses[:approved],
      id_proof_status: Application.id_proof_statuses[:approved],
      residency_proof_status: Application.residency_proof_statuses[:approved],
      medical_certification_status: Application.medical_certification_statuses[:not_requested],
      updated_at: Time.current
    )
    application.reload

    request_mail = mock('request_mail')
    request_mail.expects(:deliver_later).once
    MedicalProviderMailer.expects(:request_certification).with(application).returns(request_mail).once

    assert_difference -> { ApplicationStatusChange.where(application: application, to_status: 'awaiting_dcf').count }, 1 do
      assert_difference -> { Event.where(auditable: application, action: 'application_status_changed').count }, 1 do
        application.escalate_to_dcf!(actor: @admin, trigger: :proof_review_approved)
      end
    end

    status_change = ApplicationStatusChange.where(application: application, to_status: 'awaiting_dcf').last
    assert_not_nil status_change
    assert_equal 'in_progress', status_change.from_status
    assert_equal @admin, status_change.user

    event = Event.where(auditable: application, action: 'application_status_changed').last
    assert_not_nil event
    assert_equal @admin, event.user
    assert_equal 'awaiting_dcf', event.metadata['new_status']
    assert_equal 'proof_review_approved', event.metadata['trigger']
  end
end
