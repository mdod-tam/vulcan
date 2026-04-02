# frozen_string_literal: true

require 'test_helper'

class ApplicationLifecycleFlowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
    FeatureFlag.disable!(:vouchers_enabled)
  end

  test 'explicit certification resend is allowed when certification is already requested' do
    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents
      set_application_state(
        application,
        status: :awaiting_dcf,
        income_proof_status: :approved,
        residency_proof_status: :approved,
        medical_certification_status: :requested
      )
      application.update_columns(
        medical_certification_requested_at: 2.days.ago,
        medical_certification_request_count: 1,
        updated_at: Time.current
      )

      service = Applications::MedicalCertificationService.new(
        application: application,
        actor: admin
      )

      assert_difference -> { application.reload.medical_certification_request_count }, 1 do
        assert_difference -> { Notification.where(notifiable: application, action: 'medical_certification_requested').count }, 1 do
          assert_difference -> { Event.where(auditable: application, action: 'medical_certification_requested').count }, 1 do
            assert_difference -> { ApplicationStatusChange.where(application: application).count }, 1 do
              assert_enqueued_with(job: MedicalCertificationEmailJob) do
                result = service.request_certification
                assert result.success?, result.message
              end
            end
          end
        end
      end

      application.reload

      assert_equal 'requested', application.medical_certification_status
      assert_equal 'awaiting_dcf', application.status

      latest_notification = Notification.where(notifiable: application, action: 'medical_certification_requested').order(:created_at).last
      assert_equal 2, latest_notification.metadata['request_count']

      latest_status_change = ApplicationStatusChange.where(application: application).order(:created_at).last
      assert_equal 'requested', latest_status_change.to_status
      assert_equal 'medical_certification', latest_status_change.metadata['change_type']
    end
  end

  test 'final proof approval moves application to awaiting_dcf and requests certification once' do
    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :not_reviewed,
        medical_certification_status: :not_requested
      )

      request_mail = mock('request_mail')
      request_mail.expects(:deliver_later).once
      MedicalProviderMailer.expects(:request_certification).with do |app|
        app.id == application.id
      end.returns(request_mail).once

      reviewer = Applications::ProofReviewer.new(application, admin)

      assert_difference -> { application.proof_reviews.where(proof_type: :residency, status: :approved).count }, 1 do
        reviewer.review(proof_type: :residency, status: :approved)
      end

      application.reload

      assert_equal 'approved', application.residency_proof_status
      assert_equal 'awaiting_dcf', application.status
      assert_equal 'requested', application.medical_certification_status

      dcf_status_changes = ApplicationStatusChange.where(application: application, to_status: 'awaiting_dcf')
      assert_equal 1, dcf_status_changes.count
    end
  end

  # CHARACTERIZATION: ProofReviewer uses update_column for both proof status and
  # application status, so log_status_change (after_update) never fires. This means
  # no ApplicationStatusChange and no application_status_changed event are created.
  # Only the manually-logged application_auto_approved event exists.
  # This gap is documented in the lifecycle refactor plan (Problem #2) and will be
  # fixed when ProofReviewer is migrated through the WorkflowReconciler (PR 4).
  test 'proof reviewer auto-approval creates application_auto_approved but no status change record' do
    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents(
        attach_medical_certification: true
      )
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :not_reviewed,
        medical_certification_status: :approved
      )

      reviewer = Applications::ProofReviewer.new(application, admin)

      assert_difference -> { application.proof_reviews.where(proof_type: :residency, status: :approved).count }, 1 do
        assert_difference -> { Event.where(auditable: application, action: 'application_auto_approved').count }, 1 do
          reviewer.review(proof_type: :residency, status: :approved)
        end
      end

      application.reload

      assert_equal 'approved', application.status

      # update_column bypasses after_update :log_status_change, so no ApplicationStatusChange
      assert_equal 0, ApplicationStatusChange.where(application: application, to_status: 'approved').count

      # No application_status_changed event either (same bypass)
      approved_status_events = Event.where(auditable: application, action: 'application_status_changed').select do |event|
        event.metadata['new_status'] == 'approved'
      end
      assert_equal 0, approved_status_events.count

      # The only audit artifact is the manually-created event from ProofReviewer
      auto_approval_event = Event.where(auditable: application, action: 'application_auto_approved').order(:created_at).last
      refute_nil auto_approval_event
      assert_equal admin, auto_approval_event.user
    end
  end

  # TARGET: After PR 4 migrates ProofReviewer through WorkflowReconciler, auto-approval
  # via proof review should produce the full audit trail. Unskip this test and delete the
  # characterization test above when that migration lands.
  test 'PR4 target: proof reviewer auto-approval creates full audit artifacts' do
    skip 'Requires PR 4: migrate ProofReviewer auto-approval through WorkflowReconciler'

    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents(
        attach_medical_certification: true
      )
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :not_reviewed,
        medical_certification_status: :approved
      )

      reviewer = Applications::ProofReviewer.new(application, admin)

      assert_difference -> { application.proof_reviews.where(proof_type: :residency, status: :approved).count }, 1 do
        assert_difference -> { Event.where(auditable: application, action: 'application_auto_approved').count }, 1 do
          reviewer.review(proof_type: :residency, status: :approved)
        end
      end

      application.reload

      assert_equal 'approved', application.status
      assert_equal 1, ApplicationStatusChange.where(application: application, to_status: 'approved').count

      approved_status_events = Event.where(auditable: application, action: 'application_status_changed').select do |event|
        event.metadata['new_status'] == 'approved'
      end
      assert_equal 1, approved_status_events.count
      assert_equal admin, approved_status_events.first.user

      auto_approval_event = Event.where(auditable: application, action: 'application_auto_approved').order(:created_at).last
      refute_nil auto_approval_event
      assert_equal admin, auto_approval_event.user
    end
  end

  test 'explicit document request keeps documents_requested behavior and requests certification' do
    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :approved,
        medical_certification_status: :not_requested
      )

      request_mail = mock('request_mail')
      request_mail.expects(:deliver_later).once
      MedicalProviderMailer.expects(:request_certification).with do |app|
        app.id == application.id
      end.returns(request_mail).once

      service = Applications::DocumentRequester.new(application, by: admin)

      assert_difference -> { Event.where(auditable: application, action: 'documents_requested').count }, 1 do
        assert_difference -> { Notification.where(notifiable: application, action: 'documents_requested').count }, 1 do
          assert service.call
        end
      end

      application.reload

      assert_equal 'awaiting_dcf', application.status
      assert_equal 'requested', application.medical_certification_status
      assert_equal 1, ApplicationStatusChange.where(application: application, to_status: 'awaiting_dcf').count
    end
  end

  test 'explicit document request does not duplicate certification request when already requested' do
    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :approved,
        medical_certification_status: :requested
      )

      MedicalProviderMailer.expects(:request_certification).never

      service = Applications::DocumentRequester.new(application, by: admin)

      assert_difference -> { Event.where(auditable: application, action: 'documents_requested').count }, 1 do
        assert_difference -> { Notification.where(notifiable: application, action: 'documents_requested').count }, 1 do
          assert_no_difference -> { ApplicationStatusChange.where(application: application, change_type: 'medical_certification').count } do
            assert service.call
          end
        end
      end

      application.reload

      assert_equal 'awaiting_dcf', application.status
      assert_equal 'requested', application.medical_certification_status
      assert_equal 1, ApplicationStatusChange.where(application: application, to_status: 'awaiting_dcf').count
    end
  end

  # CHARACTERIZATION: MedicalCertificationAttachmentService uses update_columns for
  # cert status, which bypasses all after_save callbacks including auto_approve_if_eligible.
  # The application remains in_progress even though all three requirements are now met.
  # This gap is documented in the lifecycle refactor plan (Problem #2, writer list) and
  # will be fixed when cert approval paths call the WorkflowReconciler (PR 4).
  test 'certification approval does not auto-approve because update_columns bypasses callbacks' do
    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents(
        attach_medical_certification: true
      )
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :approved,
        medical_certification_status: :requested
      )

      result = MedicalCertificationAttachmentService.update_certification_status(
        application: application,
        status: :approved,
        admin: admin,
        submission_method: :admin_review
      )

      assert result[:success], 'Certification approval should succeed'

      application.reload

      assert_equal 'approved', application.medical_certification_status

      # Application status does NOT change — update_columns bypasses auto_approve_if_eligible
      assert_equal 'in_progress', application.status

      # No auto-approval artifacts because the callback path never fires
      assert_equal 0, Event.where(auditable: application, action: 'application_auto_approved').count
      assert_equal 0, ApplicationStatusChange.where(
        application: application, to_status: 'approved'
      ).where.not(change_type: 'medical_certification').count

      # The service DOES create its own medical_certification status change record
      cert_change = ApplicationStatusChange.where(
        application: application,
        change_type: 'medical_certification',
        to_status: 'approved'
      ).last
      refute_nil cert_change
      assert_equal 'requested', cert_change.from_status

      # And the service creates its own audit event
      cert_event = Event.where(auditable: application, action: 'medical_certification_status_changed').last
      refute_nil cert_event
      assert_equal admin, cert_event.user
    end
  end

  # TARGET: After PR 4 migrates cert approval paths to call WorkflowReconciler,
  # approving the final requirement should auto-approve the application. Unskip this
  # test and delete the characterization test above when that migration lands.
  test 'PR4 target: certification approval auto-approves the application' do
    skip 'Requires PR 4: migrate cert approval through WorkflowReconciler'

    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents(
        attach_medical_certification: true
      )
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :approved,
        medical_certification_status: :requested
      )

      result = MedicalCertificationAttachmentService.update_certification_status(
        application: application,
        status: :approved,
        admin: admin,
        submission_method: :admin_review
      )

      assert result[:success], 'Certification approval should succeed'

      application.reload

      assert_equal 'approved', application.medical_certification_status
      assert_equal 'approved', application.status
      assert_equal 1, ApplicationStatusChange.where(application: application, to_status: 'approved').count
      assert_equal 1, Event.where(auditable: application, action: 'application_auto_approved').count

      approved_status_events = Event.where(auditable: application, action: 'application_status_changed').select do |event|
        event.metadata['new_status'] == 'approved'
      end
      assert_equal 1, approved_status_events.count
      assert_equal admin, approved_status_events.first.user

      auto_approval_event = Event.where(auditable: application, action: 'application_auto_approved').order(:created_at).last
      refute_nil auto_approval_event
      assert_equal admin, auto_approval_event.user
    end
  end

  test 'explicit admin approval creates exact audit artifacts and initial voucher' do
    with_after_commit_callbacks do
      admin = create(:admin)
      Current.user = admin
      FeatureFlag.enable!(:vouchers_enabled)

      application = create_application_with_documents(
        attach_medical_certification: true
      )
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :approved,
        medical_certification_status: :approved
      )

      service = Applications::Approver.new(application, by: admin)

      assert_difference -> { Voucher.where(application: application).count }, 1 do
        assert_difference -> { Event.where(auditable: application, action: 'application_approved').count }, 1 do
          assert_difference -> { Event.where(action: 'voucher_assigned', auditable_type: 'Voucher').count }, 1 do
          assert service.call
          end
        end
      end

      application.reload

      assert_equal 'approved', application.status
      assert_equal 1, ApplicationStatusChange.where(application: application, to_status: 'approved').count

      approved_status_events = Event.where(auditable: application, action: 'application_status_changed').select do |event|
        event.metadata['new_status'] == 'approved'
      end
      assert_equal 1, approved_status_events.count
      assert_equal admin, approved_status_events.first.user

      approval_event = Event.where(auditable: application, action: 'application_approved').order(:created_at).last
      refute_nil approval_event
      assert_equal admin, approval_event.user

      voucher = Voucher.find_by!(application: application)
      assert voucher.persisted?
      voucher_assignment_event = Event.find_by!(auditable: voucher, action: 'voucher_assigned')
      assert_equal admin, voucher_assignment_event.user
    end
  end

  # CHARACTERIZATION: When status changes via update! (e.g. Approver, DocumentRequester),
  # the after_update :log_status_change callback fires and creates both an
  # ApplicationStatusChange and an application_status_changed event. This is the
  # callback-driven path — contrast with the update_column path tested above.
  test 'update! status change creates ApplicationStatusChange and event via callback' do
    with_after_commit_callbacks do
      admin = create(:admin)
      Current.user = admin

      application = create_application_with_documents
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :approved,
        medical_certification_status: :not_requested
      )

      assert_difference -> { ApplicationStatusChange.where(application: application).count }, 1 do
        assert_difference -> { Event.where(auditable: application, action: 'application_status_changed').count }, 1 do
          application.update!(status: :awaiting_dcf)
        end
      end

      change = ApplicationStatusChange.where(application: application, to_status: 'awaiting_dcf').last
      refute_nil change
      assert_equal 'in_progress', change.from_status
      assert_equal admin, change.user

      event = Event.where(auditable: application, action: 'application_status_changed').last
      assert_equal admin, event.user
      assert_equal 'awaiting_dcf', event.metadata['new_status']
    end
  end

  # BUG FIX TEST: Previously, if log_status_change was called with acting_user.blank?,
  # the method returned early before the ensure block, leaving @pending_status_change_user
  # and @pending_status_change_notes set. A subsequent status change on the same instance
  # would then use those stale values for actor attribution.
  test 'log_status_change clears pending ivars even when acting_user is blank' do
    with_after_commit_callbacks do
      application = create_application_with_documents
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :not_reviewed,
        residency_proof_status: :not_reviewed,
        medical_certification_status: :not_requested
      )

      # Set up the blank-actor condition:
      # pending user is nil, Current.user is nil, and stub `user` to return nil
      application.instance_variable_set(:@pending_status_change_user, nil)
      application.instance_variable_set(:@pending_status_change_notes, 'stale notes from prior call')
      Current.user = nil
      application.stubs(:user).returns(nil)

      # Call the private method directly — acting_user will be blank
      application.send(:log_status_change)

      # After the early return, pending ivars must be cleared (this is the fix)
      assert_nil application.instance_variable_get(:@pending_status_change_user)
      assert_nil application.instance_variable_get(:@pending_status_change_notes)
    end
  end

  private

  def with_after_commit_callbacks
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
    yield
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
    DatabaseCleaner.strategy = :transaction
  end

  def create_application_with_documents(
    attach_income_proof: true,
    attach_residency_proof: true,
    attach_medical_certification: false
  )
    application = create(
      :application,
      skip_proofs: true,
      status: :in_progress,
      income_proof_status: :not_reviewed,
      residency_proof_status: :not_reviewed,
      medical_certification_status: :not_requested
    )

    attach_pdf(application.income_proof, 'income.pdf') if attach_income_proof
    attach_pdf(application.residency_proof, 'residency.pdf') if attach_residency_proof
    attach_pdf(application.medical_certification, 'medical-certification.pdf') if attach_medical_certification

    application.reload
  end

  def set_application_state(application, status:, income_proof_status:, residency_proof_status:, medical_certification_status:)
    application.update_columns(
      status: Application.statuses.fetch(status.to_s),
      income_proof_status: Application.income_proof_statuses.fetch(income_proof_status.to_s),
      residency_proof_status: Application.residency_proof_statuses.fetch(residency_proof_status.to_s),
      medical_certification_status: Application.medical_certification_statuses.fetch(medical_certification_status.to_s),
      updated_at: Time.current
    )

    application.reload
  end

  def attach_pdf(attachment, filename)
    attachment.attach(
      io: StringIO.new("PDF content for #{filename}"),
      filename: filename,
      content_type: 'application/pdf'
    )
  end
end
