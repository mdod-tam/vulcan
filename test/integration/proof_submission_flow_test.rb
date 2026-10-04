# frozen_string_literal: true

require 'test_helper'

class ProofSubmissionFlowTest < ActionDispatch::IntegrationTest
  include ActionDispatch::TestProcess::FixtureFile

  setup do
    setup_clean_test_environment

    Policy.find_or_create_by!(key: 'proof_submission_rate_limit_web') { |p| p.value = 10 }
    Policy.find_or_create_by!(key: 'proof_submission_rate_limit_email') { |p| p.value = 5 }
    Policy.find_or_create_by!(key: 'proof_submission_rate_period') { |p| p.value = 24 }

    @user = create(:constituent, email: 'johnny-test@example.com')
    @application = create(:application, :paper_rejected_proofs, user: @user)
    @valid_pdf = fixture_file_upload('test/fixtures/files/medical_certification_valid.pdf', 'application/pdf')

    sign_in_for_integration_test(@user)
    assert_authenticated(@user)

    # Preserve the test-user header after the redirect.
    def follow_redirect_with_user!
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
    end
  end

  teardown do
    clear_current_context
  end

  test 'submits proof successfully when proof is rejected' do
    assert_changes '@application.reload.income_proof_status',
                   from: 'rejected',
                   to: 'not_reviewed' do
      before_value = @application.needs_review_since
      assert_difference -> { Notification.where(notifiable: @application, action: 'income_proof_attached').count }, 1 do
        assert_no_difference -> { Notification.where(notifiable: @application, action: 'proof_submitted').count } do
          assert_difference 'Event.count', 2 do # ProofAttachmentService records attachment. The controller records submission.
            post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
                 params: { proof_type: 'income', income_proof: @valid_pdf }

            assert_response :redirect
            follow_redirect_with_user!
            assert_equal 'Proof submitted successfully', flash[:notice]

            @application.reload
            assert @application.needs_review_since != before_value, 'needs_review_since should be updated'

            assert @application.income_proof.attached?, 'Income proof should be attached'
            assert_equal 'not_reviewed', @application.income_proof_status
            assert_not_nil @application.needs_review_since

            assert_audit_and_events
          end
        end
      end
    end
  end

  test 'cannot submit proof if not rejected' do
    # Bypass validation to isolate the proof-status guard.
    @application.update_column(:income_proof_status, Application.income_proof_statuses[:not_reviewed])

    @application.income_proof.detach if @application.income_proof.attached?
    @application.reload

    assert_no_changes '@application.reload.income_proof_status' do
      assert_no_difference 'Event.count' do
        post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
             params: { proof_type: 'income', income_proof: @valid_pdf }

        assert_response :redirect
        follow_redirect_with_user!
        assert_equal 'Invalid proof type or status', flash[:alert]

        @application.reload
        assert_not @application.income_proof.attached?, 'Income proof should not be attached'
      end
    end
  end

  def assert_audit_and_events
    attachment_events = Event.where(action: 'income_proof_attached').order(created_at: :desc)
    tracking_events = Event.where(action: 'proof_submitted').order(created_at: :desc)

    assert_equal 1, attachment_events.count, 'Expected 1 income_proof_attached event'
    assert_equal 1, tracking_events.count, 'Expected 1 proof_submitted event'

    # Controller audit event.
    tracking_event = tracking_events.first
    assert_equal 'proof_submitted', tracking_event.action
    assert_equal @user, tracking_event.user
    assert_equal @application, tracking_event.auditable
    assert_equal 'income', tracking_event.metadata['proof_type']
    assert_equal 'web', tracking_event.metadata['submission_method']

    # Attachment service audit event.
    attachment_event = attachment_events.first
    assert_equal 'income_proof_attached', attachment_event.action
    assert_equal @user, attachment_event.user
    assert_equal @application, attachment_event.auditable
    assert_equal 'income', attachment_event.metadata['proof_type']
    assert_equal 'web', attachment_event.metadata['submission_method']
  end

  test 'requires authentication' do
    path = "/constituent_portal/applications/#{@application.id}/proofs/resubmit"

    @application.update_column(:income_proof_status, Application.income_proof_statuses[:rejected])
    @application.income_proof.detach if @application.income_proof.attached?
    @application.reload
    assert_not @application.income_proof.attached?, 'Setup: Income proof should not be attached initially'

    # Authenticated request.
    post path, params: { proof_type: 'income', income_proof: @valid_pdf }
    assert_response :redirect
    @application.reload
    assert @application.income_proof.attached?, 'Proof should be attached after authenticated post'

    # Remove the first upload before the unauthenticated request.
    @application.income_proof.detach
    @application.save!(validate: false)
    @application.reload
    assert_not @application.income_proof.attached?, 'Proof should be detached before unauthenticated post attempt'

    # Exercise the real sign-out action before helper cleanup.
    delete sign_out_path
    assert_response :redirect
    assert_redirected_to sign_in_path

    # Clear the test helper's remaining authentication state.
    sign_out

    assert_authentication_required

    # Unauthenticated request.
    post path, params: { proof_type: 'income', income_proof: @valid_pdf }

    assert_response :redirect
    assert_redirected_to sign_in_path

    @application.reload
    assert_not @application.income_proof.attached?, 'Income proof should not be attached when not authenticated'
  end
end
