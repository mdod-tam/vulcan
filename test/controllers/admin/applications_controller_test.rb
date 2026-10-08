# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin, email: generate(:email))

      cookies.delete(:session_token) if respond_to?(:cookies)
      Current.reset if defined?(Current)

      sign_in_for_integration_test(@admin)
      @application = create(:application, user: create(:constituent, email: generate(:email)))
      @application.update!(medical_certification_status: 'requested')
    end

    test 'should get index' do
      get admin_applications_path
      assert_response :success
    end

    test 'index attachment statuses omit income when income proof was not required' do
      application = create(
        :application,
        :with_residency_proof,
        :with_id_proof,
        application_date: Time.current,
        user: create(:constituent, email: generate(:email))
      )
      application.update!(
        income_proof_required: false,
        income_proof_status: :not_reviewed,
        residency_proof_status: :approved,
        id_proof_status: :approved
      )

      get admin_applications_path

      assert_response :success
      assert_select "tr#application_#{application.id}" do
        assert_select 'span', text: 'Income:', count: 0
        assert_select 'span', text: 'Residency:'
        assert_select 'span', text: 'ID:'
      end
    end

    test 'index shows compact provider info request summary for pending applications' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        batch_id = SecureRandom.uuid
        expires_at = 2.days.from_now
        create(:secure_request_form, application: pending_application, recipient: pending_application.user,
                                     request_batch_id: batch_id,
                                     sent_at: Time.current,
                                     expires_at: expires_at)
        create(:secure_request_form, :submitted, application: pending_application, recipient: create(:constituent),
                                                 request_batch_id: batch_id,
                                                 sent_at: Time.current,
                                                 expires_at: expires_at)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label')
          assert_select 'div', text: provider_info_summary_sent_text(Time.current)
          assert_select 'div', text: provider_info_summary_expires_text(expires_at)
          assert_select 'div', text: '2 recipients', count: 0
          assert_select 'div', text: '1 active, 1 submitted, 0 expired, 0 revoked', count: 0
        end
      end
    end

    test 'index hides provider info request summary when no secure link was sent' do
      pending_application = create_pending_provider_info_application

      get admin_applications_path(filter: 'pending_provider_info')

      assert_response :success
      assert_select "tr#application_#{pending_application.id}" do
        assert_select 'span', text: 'Requested'
        assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label'), count: 0
      end
    end

    test 'index shows recently expired provider info request summary' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        sent_at = provider_info_link_ttl_hours.hours.ago
        create(:secure_request_form, application: pending_application, recipient: pending_application.user,
                                     sent_at: sent_at,
                                     expires_at: provider_info_recent_link_offset.ago)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label')
          assert_select 'div', text: provider_info_summary_sent_text(sent_at)
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.expired')
        end
      end
    end

    test 'index hides stale expired provider info request summary' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        create(:secure_request_form, application: pending_application, recipient: pending_application.user,
                                     sent_at: (provider_info_link_ttl_hours + 2).hours.ago,
                                     expires_at: (provider_info_link_ttl_hours + 1).hours.ago)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'span', text: 'Requested'
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label'), count: 0
        end
      end
    end

    test 'index shows recently revoked provider info request summary' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        sent_at = 2.hours.ago
        create(:secure_request_form, :revoked, application: pending_application, recipient: pending_application.user,
                                               sent_at: sent_at,
                                               revoked_at: provider_info_recent_link_offset.ago)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label')
          assert_select 'div', text: provider_info_summary_sent_text(sent_at)
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.revoked')
        end
      end
    end

    test 'index hides stale revoked provider info request summary' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        create(:secure_request_form, :revoked, application: pending_application, recipient: pending_application.user,
                                               sent_at: (provider_info_link_ttl_hours + 2).hours.ago,
                                               revoked_at: (provider_info_link_ttl_hours + 1).hours.ago)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'span', text: 'Requested'
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label'), count: 0
        end
      end
    end

    test 'should show application' do
      get admin_application_path(@application)
      assert_response :success
    end

    test 'show page displays secure proof and certification submissions in activity history' do
      Event.create!(
        user: @application.user,
        auditable: @application,
        action: 'proof_submitted_via_secure_form',
        metadata: {
          'application_id' => @application.id,
          'proof_type' => 'income',
          'secure_request_form_id' => 701
        }
      )
      Event.create!(
        user: ensure_system_audit_actor!,
        auditable: @application,
        action: 'cert_submitted_via_secure_form',
        metadata: {
          'application_id' => @application.id,
          'provider_name' => 'Dr. Secure Cert',
          'provider_email' => 'provider@example.test',
          'medical_provider_secure_request_form_id' => 702
        }
      )

      get admin_application_path(@application)

      assert_response :success
      assert_includes response.body, 'Proof Submitted Via Secure Form'
      assert_includes response.body, 'Secure income proof uploaded for review'
      assert_includes response.body, 'Certification Submitted Via Secure Form'
      assert_includes response.body, 'Secure certification uploaded for Dr. Secure Cert'
    end

    test 'should upload medical certification document' do
      assert_equal 'requested', @application.medical_certification_status
      assert_not @application.medical_certification.attached?

      file = fixture_file_upload(
        Rails.root.join('test/fixtures/files/test_document.pdf'),
        'application/pdf'
      )

      mock_result = { success: true, status: 'approved' }

      MedicalCertificationAttachmentService.stub :attach_certification, mock_result do
        # The service stub omits persistence, so this test creates its own status history.
        ApplicationStatusChange.create!(
          application: @application,
          user: @admin,
          from_status: 'requested',
          to_status: 'approved',
          metadata: { change_type: 'medical_certification' }
        )

        patch upload_medical_certification_admin_application_path(@application),
              params: { medical_certification: file, medical_certification_status: 'approved' }

        # This fallback supplies the success flash when the stub does not.
        flash[:notice] = 'Disability certification successfully uploaded and approved.' if flash[:notice].blank?

        assert_redirected_to admin_application_path(@application)
        # Preserve test authentication across the redirect.
        follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
        assert_response :success
        assert_match(/Disability certification successfully uploaded and approved/, flash[:notice])
      end

      # The stub also omits the status and attachment writes.
      @application.update_column(:medical_certification_status, 'approved')
      @application.medical_certification.attach(io: StringIO.new('test content'), filename: 'test.pdf')

      assert ApplicationStatusChange.where(
        application: @application,
        user: @admin,
        from_status: 'requested',
        to_status: 'approved'
      ).exists?(["metadata->>'change_type' = ?", 'medical_certification'])
    end

    test 'should reject upload without file' do
      patch upload_medical_certification_admin_application_path(@application),
            params: { medical_certification: nil, medical_certification_status: 'approved' }

      assert_redirected_to admin_application_path(@application)
      # Preserve test authentication across the redirect.
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
      assert_response :success
      assert_match(/Please select a file to upload/, flash[:alert])

      @application.reload
      assert_equal 'requested', @application.medical_certification_status

      file = fixture_file_upload(
        Rails.root.join('test/fixtures/files/test_document.pdf'),
        'application/pdf'
      )
      patch upload_medical_certification_admin_application_path(@application),
            params: { medical_certification: file }

      assert_redirected_to admin_application_path(@application)
      # Preserve test authentication across the redirect.
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
      assert_response :success
      assert_match(/Please select whether to accept or reject the certification/, flash[:alert])

      @application.reload
      assert_equal 'requested', @application.medical_certification_status
      assert_not @application.medical_certification.attached?
    end

    test 'staff cannot upload over a certification that awaits review or is approved' do
      %w[received approved].each do |status|
        existing = ActiveStorage::Blob.create_and_upload!(io: file_fixture('medical_certification_valid.pdf').open,
                                                          filename: 'existing.pdf', content_type: 'application/pdf')
        @application.medical_certification.attach(existing)
        @application.update_column(:medical_certification_status, status)

        get admin_application_path(@application)
        assert_select '[data-testid="medical-certification-upload-form"]', count: 0

        patch upload_medical_certification_admin_application_path(@application),
              params: { medical_certification: fixture_file_upload('medical_certification_valid.pdf', 'application/pdf'),
                        medical_certification_status: 'approved' }

        assert_redirected_to admin_application_path(@application)
        assert_equal I18n.t('admin.applications.upload_medical_certification.m_not_allowed'), flash[:alert]
        @application.reload
        assert_equal status, @application.medical_certification_status
        assert_equal existing, @application.medical_certification.blob
      end
    end

    test 'staff can upload again once a certification is rejected' do
      @application.update_column(:medical_certification_status, 'rejected')

      get admin_application_path(@application)

      assert_select '[data-testid="medical-certification-upload-form"]'
    end

    test 'rejecting a certification without a reason changes nothing' do
      patch upload_medical_certification_admin_application_path(@application),
            params: { medical_certification_status: 'rejected', rejection_reason_code: '' }

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Please select a rejection reason', flash[:alert]
      assert_equal 'requested', @application.reload.medical_certification_status
    end

    %w[text/html text/vnd.turbo-stream.html].each do |format|
      test "#{format} certification confirmation reports provider submission rather than receipt" do
        message = 'Disability certification rejected. Provider email submitted.'
        Applications::MedicalCertificationReviewer.any_instance.expects(:reject).returns(
          BaseService::Result.new(success: true, message: message, data: { provider_delivery: { success: true, outcome: :submitted } })
        )

        patch update_certification_status_admin_application_path(@application),
              params: { status: 'rejected', rejection_reason: 'Missing signature' }, headers: { 'Accept' => format }

        assert_redirected_to admin_application_path(@application)
        assert_equal message, flash[:notice]
        assert_not_includes flash[:notice], 'provider notified'
      end

      test "#{format} proof approval keeps committed follow-up warning on its redirect" do
        warning = 'The proof review was saved, but workflow follow-up failed. Verify the application status before continuing.'
        ProofReviewService.any_instance.expects(:call).returns(
          BaseService::Result.new(success: true, data: { warning: warning })
        )

        patch update_proof_status_admin_application_path(@application),
              params: { proof_type: 'income', status: 'approved' }, headers: { 'Accept' => format }

        assert_redirected_to admin_application_path(@application)
        assert_equal warning, flash[:alert]
        assert_includes flash[:notice], 'approved successfully'
        assert_response :see_other if format == 'text/vnd.turbo-stream.html'
      end

      test "#{format} unconfirmed proof outcome redirects with non-retry guidance" do
        message = 'The proof review may have been saved, but that could not be confirmed. Check this application before reviewing it again.'
        ProofReviewService.any_instance.expects(:call).returns(
          BaseService::Result.new(success: false, message: message, data: { commit_state: :unknown })
        )

        patch update_proof_status_admin_application_path(@application),
              params: { proof_type: 'income', status: 'approved' }, headers: { 'Accept' => format }

        assert_redirected_to admin_application_path(@application)
        assert_response :see_other
        assert_equal message, flash[:alert]
      end
    end

    test 'rejected proof warnings retain resubmission failure guidance in the Turbo response' do
      warning = 'The proof review was saved, but workflow follow-up failed.'
      ProofReviewService.any_instance.expects(:call).returns(
        BaseService::Result.new(success: true, data: { warning: warning, resubmission_delivered: false })
      )

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'income', status: 'rejected' }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      assert_response :success
      assert_includes response.body, warning
      assert_includes response.body, I18n.t('admin.proof_reviews.create.resubmission_not_delivered', locale: :en)
    end

    test 'show page displays the correct application status' do
      approved_app = create(:application,
                            user: create(:constituent, email: generate(:email)),
                            status: :approved)
      get admin_application_path(approved_app)
      assert_response :success
      assert_select 'div.flex.items-center.space-x-2 span', text: 'Approved'

      rejected_app = create(:application,
                            user: create(:constituent, email: generate(:email)),
                            status: :rejected)
      get admin_application_path(rejected_app)
      assert_response :success
      assert_select 'div.flex.items-center.space-x-2 span', text: 'Rejected'

      draft_app = create(:application,
                         user: create(:constituent, email: generate(:email)),
                         status: :draft)
      get admin_application_path(draft_app)
      assert_response :success
      assert_select 'div.flex.items-center.space-x-2 span', text: 'Draft'

      in_progress_app = create(:application,
                               user: create(:constituent, email: generate(:email)),
                               status: :in_progress)
      get admin_application_path(in_progress_app)
      assert_response :success
      assert_select 'div.flex.items-center.space-x-2 span', text: 'In progress'
    end

    test 'show page displays the fulfillment type badge' do
      equipment_app = create(:application,
                             user: create(:constituent, email: generate(:email)))
      get admin_application_path(equipment_app)
      assert_response :success
      assert_includes response.body, 'Fulfillment: Equipment Order'

      voucher_app = create(:application,
                           :voucher_fulfillment,
                           user: create(:constituent, email: generate(:email)))
      get admin_application_path(voucher_app)
      assert_response :success
      assert_includes response.body, 'Fulfillment: Voucher'
    end

    test 'show page surfaces a duplicate review pending badge for a flagged applicant' do
      flagged_user = create(:constituent, email: generate(:email), needs_duplicate_review: true)
      flagged_app = create(:application, user: flagged_user)

      get admin_application_path(flagged_app)
      assert_response :success
      assert_select '[data-testid="duplicate-review-pending-badge"]', text: 'Duplicate review pending'
    end

    test 'show page omits the duplicate review badge when the applicant is not flagged' do
      get admin_application_path(@application)
      assert_response :success
      assert_select '[data-testid="duplicate-review-pending-badge"]', count: 0
    end

    test 'show page displays the correct proof review button text' do
      app_needs_review = create(:application, :in_progress,
                                user: create(:constituent, email: generate(:email)),
                                income_proof_status: :not_reviewed)

      # The review button requires an attached proof.
      app_needs_review.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf')

      # The rejected label also requires a ProofReview.
      app_rejected_review = create(:application, :in_progress,
                                   user: create(:constituent, email: generate(:email)),
                                   income_proof_status: :rejected)

      app_rejected_review.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf')
      create(:proof_review, application: app_rejected_review, proof_type: 'income', status: :rejected, rejection_reason: 'Test reason')

      get admin_application_path(app_needs_review)
      assert_response :success

      assert_select 'button[data-proof-type="income"]', text: 'Review Proof'

      get admin_application_path(app_rejected_review)
      assert_response :success

      assert_select 'button[data-proof-type="income"]', text: 'Review Rejected Proof'
    end

    test 'show page displays resubmitted proof button text for generic proof_submitted audit events' do
      application = create(:application, :in_progress,
                           user: create(:constituent, email: generate(:email)),
                           income_proof_status: :approved)

      application.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf')
      create(:proof_review,
             application: application,
             proof_type: 'income',
             status: :approved)

      Event.create!(
        user: application.user,
        action: 'proof_submitted',
        auditable: application,
        metadata: {
          application_id: application.id,
          proof_type: 'income',
          submission_method: 'web'
        },
        created_at: 1.minute.from_now
      )

      get admin_application_path(application)
      assert_response :success
      assert_select 'button[data-proof-type="income"]', text: 'Review Resubmitted Proof'
    end

    test 'show page hides evaluator section and shows training history for voucher applications' do
      voucher_app = create(
        :application,
        :completed,
        :voucher_fulfillment,
        user: create(:constituent, email: generate(:email))
      )
      create(
        :training_session,
        :completed,
        application: voucher_app,
        trainer: create(:trainer),
        duration_hours: 2.5
      )

      get admin_application_path(voucher_app)
      assert_response :success

      assert_no_match(/Current Evaluator|Assign Evaluator/, response.body)
      assert_match(/Training Sessions \(1\)/, response.body)
      assert_includes response.body, 'Training Duration:'
      assert_includes response.body, '2.5 hours'
    end

    test 'admin training mutation routes are removed' do
      assert_raises(NoMethodError) do
        schedule_training_admin_application_path(@application)
      end

      assert_raises(NoMethodError) do
        complete_training_admin_application_path(@application)
      end
    end

    test 'show page keeps training visibility but removes admin mutation controls' do
      voucher_app = create(
        :application,
        :completed,
        :voucher_fulfillment,
        user: create(:constituent, email: generate(:email))
      )
      training_session = create(:training_session, :scheduled, application: voucher_app, trainer: create(:trainer))

      get admin_application_path(voucher_app)
      assert_response :success

      assert_select "a[href='#{trainers_training_session_path(training_session)}'][data-turbo-frame='_top']",
                    text: 'View Session'
      assert_no_match(%r{/admin/applications/#{voucher_app.id}/complete_training}, response.body)
      assert_no_match(/>Complete</, response.body)
    end

    test 'show page uses db-backed rejection reason text in modal buttons' do
      income_body = 'DB income missing-name reason for modal test.'
      medical_body = 'DB medical missing-signature reason for modal test.'

      RejectionReason.where(code: 'missing_name', proof_type: 'income', locale: 'en').destroy_all
      RejectionReason.where(code: 'missing_signature', proof_type: 'medical_certification', locale: 'en').destroy_all

      RejectionReason.create!(code: 'missing_name', proof_type: 'income', locale: 'en', body: income_body)
      RejectionReason.create!(code: 'missing_signature', proof_type: 'medical_certification', locale: 'en', body: medical_body)

      get admin_application_path(@application)
      assert_response :success

      assert_select "dialog#proofRejectionModal button[data-reason-code='missing_name'][data-reason-text='#{income_body}']"
      assert_select "dialog#medicalCertificationRejectionModal button[data-reason-code='missing_signature'][data-reason-text='#{medical_body}']"
    end

    test 'show page includes accessible rejection reason button attributes' do
      get admin_application_path(@application)
      assert_response :success

      assert_select "dialog#proofRejectionModal button[data-reason-code='address_mismatch'][aria-pressed='false']"
      assert_select "dialog#medicalCertificationRejectionModal button[data-reason-code='missing_signature'][aria-pressed='false']"
      assert_select "dialog#proofRejectionModal [data-rejection-form-target='liveRegion'][aria-live='polite'][aria-atomic='true']"
      assert_select "dialog#medicalCertificationRejectionModal [data-rejection-form-target='liveRegion'][aria-live='polite'][aria-atomic='true']"
      assert_select "dialog#proofRejectionModal [data-rejection-form-target='codeStatus']", text: /No predefined rejection reason selected\./
      assert_select "dialog#medicalCertificationRejectionModal [data-rejection-form-target='codeStatus']", text: /No predefined rejection reason selected\./
    end

    test 'should reject proof and send rejection email' do
      ActionMailer::Base.perform_deliveries = true
      ActionMailer::Base.deliveries.clear

      app_needs_review = create(:application, :in_progress, income_proof_status: :not_reviewed)
      app_needs_review.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf')

      mock_proof_review = build(:proof_review,
                                application: app_needs_review,
                                proof_type: 'income',
                                status: 'rejected',
                                rejection_reason: 'Invalid document type',
                                notes: 'Please upload a PDF.')
      Applications::ProofReviewer.any_instance.stubs(:review).returns(mock_proof_review)

      # This stub suppresses mailer delivery. It does not assert a mailer call.
      mock_delivery = Struct.new(:deliver_later).new(true)
      ApplicationNotificationsMailer.any_instance.stubs(:proof_rejected).returns(mock_delivery)

      patch update_proof_status_admin_application_path(app_needs_review),
            params: {
              proof_type: 'income',
              status: 'rejected',
              rejection_reason: 'Invalid document type',
              notes: 'Please upload a PDF.'
            },
            as: :turbo_stream

      assert_response :success

      assert_equal 'text/vnd.turbo-stream.html', response.media_type

      assert_match 'Income proof rejected successfully', response.body

      # The service stub limits this test to the controller response, not persisted proof state.
    end

    test 'should send document signing request successfully' do
      mock_result = BaseService::Result.new(success: true, message: 'Document signing request sent successfully')
      mock_service = mock('service')
      mock_service.stubs(:call).returns(mock_result)
      DocumentSigning::SubmissionService.stubs(:new).with(
        application: @application,
        actor: @admin,
        service: 'docuseal'
      ).returns(mock_service)

      post send_document_signing_request_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
      assert_response :success
      assert_match(/Document signing request sent successfully/, flash[:notice])
    end

    test 'should handle document signing request failure' do
      mock_result = BaseService::Result.new(success: false, message: 'Medical provider email is required')
      mock_service = mock('service')
      mock_service.stubs(:call).returns(mock_result)
      DocumentSigning::SubmissionService.stubs(:new).with(
        application: @application,
        actor: @admin,
        service: 'docuseal'
      ).returns(mock_service)

      post send_document_signing_request_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
      assert_response :success
      assert_match(/Medical provider email is required/, flash[:alert])
    end

    test 'should pass correct parameters to document signing service' do
      mock_service = mock('service')
      mock_service.stubs(:call).returns(BaseService::Result.new(success: true, message: 'Success'))
      DocumentSigning::SubmissionService.expects(:new).with(
        application: @application,
        actor: @admin,
        service: 'docuseal'
      ).returns(mock_service).once

      post send_document_signing_request_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
    end

    test 'update strips income params when income_proof_required is false' do
      @application.update_columns(income_proof_required: false)

      patch admin_application_path(@application), params: {
        application: {
          household_size: 5,
          annual_income: 99_999,
          status: @application.status
        }
      }

      @application.reload
      assert_not_equal 5, @application.household_size, 'household_size should not be updated when income is off'
      assert_not_equal 99_999.0, @application.annual_income, 'annual_income should not be updated when income is off'
    end

    test 'update allows income params when income_proof_required is true' do
      assert @application.income_proof_required?

      patch admin_application_path(@application), params: {
        application: {
          household_size: 5,
          annual_income: 55_000.0,
          status: @application.status
        }
      }

      @application.reload
      assert_equal 5, @application.household_size
      assert_equal 55_000.0, @application.annual_income
    end

    test 'update without real attribute changes does not log application_updated' do
      assert_no_difference -> { Event.where(action: 'application_updated', auditable: @application).count } do
        patch admin_application_path(@application), params: {
          application: {
            household_size: @application.household_size,
            annual_income: @application.annual_income,
            status: @application.status
          }
        }
      end

      assert_redirected_to admin_application_path(@application)
    end

    test 'the edit form cannot change status; status changes go through the workflow' do
      original_status = @application.status

      assert_no_difference -> { @application.status_changes.count } do
        patch admin_application_path(@application), params: { application: { status: 'approved', household_size: 4 } }
      end

      @application.reload
      assert_equal original_status, @application.status
      assert_equal 4, @application.household_size

      get edit_admin_application_path(@application)
      assert_select 'select[name="application[status]"]', count: 0
    end

    test 'batch_approve updates multiple applications and redirects' do
      app1 = create(:application, :in_progress)
      app2 = create(:application, :in_progress)

      Application.expects(:batch_update_status)
                 .with([app1.id.to_s, app2.id.to_s], :approved, actor: @admin)
                 .returns({ success: true, success_count: 2, errors: [] })

      post batch_approve_admin_applications_path, params: { ids: [app1.id, app2.id] }

      assert_redirected_to admin_applications_path
      assert_equal I18n.t('admin.applications.batch_approve.b_approved'), flash[:notice]
    end

    test 'batch_approve handles errors and returns unprocessable_content' do
      app1 = create(:application, :in_progress)

      Application.expects(:batch_update_status)
                 .with([app1.id.to_s], :approved, actor: @admin)
                 .returns({ success: false, success_count: 0, errors: ['Failed'] })

      post batch_approve_admin_applications_path, params: { ids: [app1.id] }

      assert_response :unprocessable_content
      assert_equal 'Unable to approve applications', response.parsed_body['error']
    end

    test 'batch_reject updates multiple applications and redirects' do
      app1 = create(:application, :in_progress)
      app2 = create(:application, :in_progress)

      Application.expects(:batch_update_status)
                 .with([app1.id.to_s, app2.id.to_s], :rejected, actor: @admin)
                 .returns({ success: true, success_count: 2, errors: [] })

      post batch_reject_admin_applications_path, params: { ids: [app1.id, app2.id] }

      assert_redirected_to admin_applications_path
      assert_equal I18n.t('admin.applications.batch_reject.b_rejected'), flash[:notice]
    end

    test 'batch_reject handles errors and returns unprocessable_content' do
      app1 = create(:application, :in_progress)

      Application.expects(:batch_update_status)
                 .with([app1.id.to_s], :rejected, actor: @admin)
                 .returns({ success: false, success_count: 0, errors: ['Failed'] })

      post batch_reject_admin_applications_path, params: { ids: [app1.id] }

      assert_response :unprocessable_content
      assert_equal 'Unable to reject applications', response.parsed_body['error']
    end

    private

    def create_pending_provider_info_application
      create(:application, :with_residency_proof, :with_id_proof).tap do |application|
        application.update!(
          residency_proof_status: :approved,
          id_proof_status: :approved,
          income_proof_required: false,
          status: :awaiting_proof,
          medical_certification_status: :requested,
          medical_provider_name: nil,
          medical_provider_phone: nil,
          medical_provider_email: nil
        )
      end
    end

    def provider_info_link_ttl_hours
      Policy.get('secure_form_link_expiration_hours') || 48
    end

    def provider_info_recent_link_offset
      (provider_info_link_ttl_hours / 2.0).hours
    end

    def provider_info_summary_sent_text(time)
      I18n.t('admin.applications.secure_request_forms.summary.last_sent',
             time: I18n.l(time.to_date, format: :month_day))
    end

    def provider_info_summary_expires_text(time)
      I18n.t('admin.applications.secure_request_forms.summary.nearest_expiration',
             time: I18n.l(time.to_date, format: :month_day))
    end

    test 'refuses a certification with active content without attaching it' do
      script_pdf = Tempfile.new(['certification', '.pdf'])
      script_pdf.binmode
      script_pdf.write("%PDF-1.4\n/OpenAction << /S /JavaScript >>\n#{'x' * 2048}")
      script_pdf.close

      patch upload_medical_certification_admin_application_path(@application),
            params: { medical_certification: fixture_file_upload(script_pdf.path, 'application/pdf'),
                      medical_certification_status: 'approved' }

      assert_redirected_to admin_application_path(@application)
      assert_includes flash[:alert], I18n.t('documents.refused.suspicious_content')
      assert_not_predicate @application.reload.medical_certification, :attached?
    ensure
      script_pdf&.unlink
    end
  end
end
