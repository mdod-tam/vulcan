# frozen_string_literal: true

require 'test_helper'

# This test is a copy of the controller test, using the integration test approach
class ProofSubmissionFlowTest < ActionDispatch::IntegrationTest
  include ActionDispatch::TestProcess::FixtureFile

  setup do
    # Use our clean test helper for consistent setup
    setup_clean_test_environment

    # Create the required rate limit policies (per CLAUDE.md testing guidelines)
    Policy.find_or_create_by!(key: 'proof_submission_rate_limit_web') { |p| p.value = 10 }
    Policy.find_or_create_by!(key: 'proof_submission_rate_limit_email') { |p| p.value = 5 }
    Policy.find_or_create_by!(key: 'proof_submission_rate_period') { |p| p.value = 24 }

    @user = create(:constituent, email: 'johnny-test@example.com')
    @application = create(:application, :paper_rejected_proofs, user: @user)
    @valid_pdf = fixture_file_upload('test/fixtures/files/medical_certification_valid.pdf', 'application/pdf')

    # Use the sign_in helper from test_helper.rb
    sign_in_for_integration_test(@user)
    assert_authenticated(@user) # Verify authentication state

    # Helper to follow redirect with user headers
    def follow_redirect_with_user!
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
    end
  end

  teardown do
    # Use our clean helper for consistent teardown
    clear_current_context
  end

  test 'submits proof successfully when proof is rejected' do
    assert_changes '@application.reload.income_proof_status',
                   from: 'rejected',
                   to: 'not_reviewed' do
      # Instead of checking exact change in needs_review_since, just verify it gets set
      before_value = @application.needs_review_since
      assert_difference -> { Notification.where(notifiable: @application, action: 'income_proof_attached').count }, 1 do
        assert_no_difference -> { Notification.where(notifiable: @application, action: 'proof_submitted').count } do
          assert_difference 'Event.count', 2 do # ProofAttachmentService creates income_proof_attached, tracking creates proof_submitted
            # Use the direct path
            post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
                 params: { proof_type: 'income', income_proof_upload: @valid_pdf }

            # Verify response and flash
            assert_response :redirect
            follow_redirect_with_user!
            assert_equal 'Proof submitted successfully', flash[:notice]

            # Verify needs_review_since was updated
            @application.reload
            assert @application.needs_review_since != before_value, 'needs_review_since should be updated'

            # Verify application updates
            assert @application.income_proof.attached?, 'Income proof should be attached'
            assert_equal 'not_reviewed', @application.income_proof_status
            assert_not_nil @application.needs_review_since

            # Verify audit trail and events
            assert_audit_and_events
          end
        end
      end
    end
  end

  test 'cannot submit proof if not rejected' do
    # Set application to not_reviewed status (not rejected) (bypass validation)
    @application.update_column(:income_proof_status, Application.income_proof_statuses[:not_reviewed])

    # Ensure no proof is attached from previous tests
    @application.income_proof.detach if @application.income_proof.attached?
    @application.reload

    assert_no_changes '@application.reload.income_proof_status' do
      assert_no_difference 'Event.count' do
        # Use the direct path
        post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
             params: { proof_type: 'income', income_proof_upload: @valid_pdf }

        # Verify response and flash
        assert_response :redirect
        follow_redirect_with_user!
        assert_equal 'Invalid proof type or status', flash[:alert]

        # Check no proof was attached
        @application.reload
        assert_not @application.income_proof.attached?, 'Income proof should not be attached'
      end
    end
  end

  def assert_audit_and_events
    # Verify events were created (one from ProofAttachmentService, one from tracking)
    attachment_events = Event.where(action: 'income_proof_attached').order(created_at: :desc)
    tracking_events = Event.where(action: 'proof_submitted').order(created_at: :desc)

    assert_equal 1, attachment_events.count, 'Expected 1 income_proof_attached event'
    assert_equal 1, tracking_events.count, 'Expected 1 proof_submitted event'

    # Check the tracking event (from controller)
    tracking_event = tracking_events.first
    assert_equal 'proof_submitted', tracking_event.action
    assert_equal @user, tracking_event.user
    assert_equal @application, tracking_event.auditable
    assert_equal 'income', tracking_event.metadata['proof_type']
    assert_equal 'web', tracking_event.metadata['submission_method']

    # Check the attachment event (from ProofAttachmentService)
    attachment_event = attachment_events.first
    assert_equal 'income_proof_attached', attachment_event.action
    assert_equal @user, attachment_event.user
    assert_equal @application, attachment_event.auditable
    assert_equal 'income', attachment_event.metadata['proof_type']
    assert_equal 'web', attachment_event.metadata['submission_method']
  end

  test 'requires authentication' do
    path = "/constituent_portal/applications/#{@application.id}/proofs/resubmit"

    # Ensure application is in a state where proof can be submitted and no proof is initially attached
    @application.update_column(:income_proof_status, Application.income_proof_statuses[:rejected])
    @application.income_proof.detach if @application.income_proof.attached?
    @application.reload
    assert_not @application.income_proof.attached?, 'Setup: Income proof should not be attached initially'

    # A. Authenticated POST: Should succeed and attach the proof.
    post path, params: { proof_type: 'income', income_proof_upload: @valid_pdf }
    assert_response :redirect
    @application.reload
    assert @application.income_proof.attached?, 'Proof should be attached after authenticated post'

    # B. Detach proof to reset state for unauthenticated check
    @application.income_proof.detach
    @application.save!(validate: false) # Skip validation for test setup
    @application.reload
    assert_not @application.income_proof.attached?, 'Proof should be detached before unauthenticated post attempt'

    # C. Sign out using the actual controller action to test the real flow
    delete sign_out_path
    assert_response :redirect
    assert_redirected_to sign_in_path

    # Use the proper sign_out helper to clear all authentication state
    sign_out

    # Verify we are no longer authenticated
    assert_authentication_required

    # D. Unauthenticated POST: Should redirect unauthenticated user to sign_in and NOT attach any proof.
    post path, params: { proof_type: 'income', income_proof_upload: @valid_pdf }

    # Check for redirect to sign in
    assert_response :redirect
    assert_redirected_to sign_in_path

    # Verify no changes occurred
    @application.reload
    assert_not @application.income_proof.attached?, 'Income proof should not be attached when not authenticated'
  end
end
