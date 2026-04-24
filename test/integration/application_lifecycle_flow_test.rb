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
        id_proof_status: :approved,
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
        id_proof_status: :approved,
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

  test 'proof reviewer auto-approval creates canonical status audit artifacts' do
    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents(
        attach_medical_certification: true
      )
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        id_proof_status: :approved,
        residency_proof_status: :not_reviewed,
        medical_certification_status: :approved
      )

      reviewer = Applications::ProofReviewer.new(application, admin)

      assert_difference -> { application.proof_reviews.where(proof_type: :residency, status: :approved).count }, 1 do
        assert_difference -> { Event.where(auditable: application, action: 'application_status_changed').count }, 1 do
          reviewer.review(proof_type: :residency, status: :approved)
        end
      end

      application.reload

      assert_equal 'approved', application.status

      approved_changes = ApplicationStatusChange.where(application: application, to_status: 'approved').where(change_type: [nil, ''])
      assert_equal 1, approved_changes.count
      assert_equal 'auto_approval', approved_changes.first.metadata['trigger']

      approved_status_events = Event.where(auditable: application, action: 'application_status_changed').select do |event|
        event.metadata['new_status'] == 'approved'
      end
      assert_equal 1, approved_status_events.count
      assert_equal 'auto_approval', approved_status_events.first.metadata['trigger']
      assert_equal admin, approved_status_events.first.user
      assert_equal 0, Event.where(auditable: application, action: 'application_auto_approved').count
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
        id_proof_status: :approved,
        medical_certification_status: :approved
      )

      reviewer = Applications::ProofReviewer.new(application, admin)

      assert_difference -> { application.proof_reviews.where(proof_type: :residency, status: :approved).count }, 1 do
        assert_no_difference -> { Event.where(auditable: application, action: 'application_auto_approved').count } do
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
      assert_equal 'auto_approval', approved_status_events.first.metadata['trigger']
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
        id_proof_status: :approved,
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
        id_proof_status: :approved,
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

  test 'certification approval auto-approves the application via reconciler' do
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
        id_proof_status: :approved,
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

      # Exactly 1 ApplicationStatusChange to approved (from reconciler via transition_status!)
      approved_status_changes = ApplicationStatusChange.where(
        application: application, to_status: 'approved'
      ).where(change_type: [nil, ''])
      assert_equal 1, approved_status_changes.count

      # Exactly 1 application_status_changed event with trigger: auto_approval
      approved_status_events = Event.where(
        auditable: application, action: 'application_status_changed'
      ).select { |e| e.metadata['new_status'] == 'approved' }
      assert_equal 1, approved_status_events.count
      assert_equal 'auto_approval', approved_status_events.first.metadata['trigger']
      assert_equal admin, approved_status_events.first.user

      # No legacy application_auto_approved events
      assert_equal 0, Event.where(auditable: application, action: 'application_auto_approved').count
    end
  end

  test 'proof reviewer auto-approval creates canonical audit artifacts' do
    with_after_commit_callbacks do
      admin = create(:admin)
      application = create_application_with_documents(
        attach_medical_certification: true
      )
      set_application_state(
        application,
        status: :awaiting_dcf,
        income_proof_status: :approved,
        residency_proof_status: :not_reviewed,
        id_proof_status: :approved,
        medical_certification_status: :approved
      )

      reviewer = Applications::ProofReviewer.new(application, admin)
      reviewer.review(proof_type: :residency, status: :approved)

      application.reload

      assert_equal 'approved', application.status

      # Exactly 1 ApplicationStatusChange to approved with trigger metadata
      approved_changes = ApplicationStatusChange.where(
        application: application, to_status: 'approved'
      ).where(change_type: [nil, ''])
      assert_equal 1, approved_changes.count
      assert_equal 'auto_approval', approved_changes.first.metadata['trigger']

      # Exactly 1 application_status_changed event with trigger: auto_approval
      approved_events = Event.where(
        auditable: application, action: 'application_status_changed'
      ).select { |e| e.metadata['new_status'] == 'approved' }
      assert_equal 1, approved_events.count
      assert_equal 'auto_approval', approved_events.first.metadata['trigger']

      # No legacy application_auto_approved events
      assert_equal 0, Event.where(auditable: application, action: 'application_auto_approved').count
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
        id_proof_status: :approved,
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
      assert_not_nil approval_event
      assert_equal admin, approval_event.user

      voucher = Voucher.find_by!(application: application)
      assert voucher.persisted?
      voucher_assignment_event = Event.find_by!(auditable: voucher, action: 'voucher_assigned')
      assert_equal admin, voucher_assignment_event.user
    end
  end

  # CHARACTERIZATION: When status changes via transition_status! (e.g. Approver, DocumentRequester),
  # it creates both an ApplicationStatusChange and an application_status_changed event.
  # This is the explicit API-driven path.
  test 'transition_status! creates ApplicationStatusChange and application_status_changed for manual path' do
    with_after_commit_callbacks do
      admin = create(:admin)

      application = create_application_with_documents
      set_application_state(
        application,
        status: :in_progress,
        income_proof_status: :approved,
        residency_proof_status: :approved,
        id_proof_status: :approved,
        medical_certification_status: :not_requested
      )

      assert_difference -> { ApplicationStatusChange.where(application: application).count }, 1 do
        assert_difference -> { Event.where(auditable: application, action: 'application_status_changed').count }, 1 do
          application.transition_status!(:awaiting_dcf, actor: admin, metadata: { trigger: 'test' })
        end
      end

      change = ApplicationStatusChange.where(application: application, to_status: 'awaiting_dcf').last
      assert_not_nil change
      assert_equal 'in_progress', change.from_status
      assert_equal admin, change.user

      event = Event.where(auditable: application, action: 'application_status_changed').last
      assert_equal admin, event.user
      assert_equal 'awaiting_dcf', event.metadata['new_status']
    end
  end

  # (Deleted stale log_status_change test here as the method and ivars were removed in PR 99)

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
    attach_id_proof: true,
    attach_medical_certification: false
  )
    application = create(
      :application,
      skip_proofs: true,
      status: :in_progress,
      income_proof_status: :not_reviewed,
      residency_proof_status: :not_reviewed,
      id_proof_status: :not_reviewed,
      medical_certification_status: :not_requested
    )

    attach_pdf(application.income_proof, 'income.pdf') if attach_income_proof
    attach_pdf(application.residency_proof, 'residency.pdf') if attach_residency_proof
    attach_pdf(application.id_proof, 'id-proof.pdf') if attach_id_proof
    attach_pdf(application.medical_certification, 'medical-certification.pdf') if attach_medical_certification

    application.reload
  end

  def set_application_state(application, status:, income_proof_status:, residency_proof_status:, id_proof_status:, medical_certification_status:)
    application.update_columns(
      status: Application.statuses.fetch(status.to_s),
      income_proof_status: Application.income_proof_statuses.fetch(income_proof_status.to_s),
      residency_proof_status: Application.residency_proof_statuses.fetch(residency_proof_status.to_s),
      id_proof_status: Application.id_proof_statuses.fetch(id_proof_status.to_s),
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
