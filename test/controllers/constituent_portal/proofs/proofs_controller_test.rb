# frozen_string_literal: true

require 'test_helper'

# NOTE: We're using a generic test class name to avoid namespace conflicts
# between the Constituent model class and the constituent_portal namespace in our routes/controllers.
# The controller lives in app/controllers/constituent_portal/proofs and we're testing it in the correct namespace.
class ConstituentProofsSubmissionTest < ActionDispatch::IntegrationTest
  include ActionDispatch::TestProcess::FixtureFile

  setup do
    # Use factories instead of fixtures
    @user = create(:constituent)

    # Create application with rejected income proof using the paper trait
    @application = create(:application, :paper_rejected_proofs, user: @user)

    @valid_pdf = fixture_file_upload('test/fixtures/files/medical_certification_valid.pdf', 'application/pdf')

    # Use the sign_in helper from test_helper.rb
    sign_in_for_integration_test(@user)

    # Set up rate limit policies with proper user context for policy changes
    proof_limit_policy = Policy.find_or_initialize_by(key: 'proof_submission_rate_limit_web')
    proof_limit_policy.value = 5
    proof_limit_policy.updated_by = @user
    proof_limit_policy.save!

    proof_period_policy = Policy.find_or_initialize_by(key: 'proof_submission_rate_period')
    proof_period_policy.value = 1
    proof_period_policy.updated_by = @user
    proof_period_policy.save!

    # Set default host for Active Storage URL generation in tests
    Rails.application.routes.default_url_options[:host] = 'www.example.com'
  end

  test 'submits proof successfully when proof is rejected' do
    # Clear events before the test to ensure we only count events from this test
    Event.delete_all

    assert_changes '@application.reload.income_proof_status',
                   from: 'rejected',
                   to: 'not_reviewed' do
      # Instead of checking exact change in needs_review_since, just verify it gets set
      before_value = @application.needs_review_since
      assert_difference 'Event.count', 2 do # ProofAttachmentService creates income_proof_attached, tracking creates proof_submitted
        # Using the new namespace path directly
        post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
             params: { proof_type: 'income', income_proof: @valid_pdf }

        # Verify redirect
        assert_redirected_to constituent_portal_application_path(@application)
        # Verify flash
        assert_equal 'Proof submitted successfully', flash[:notice]

        # Verify needs_review_since was updated
        @application.reload
        assert @application.needs_review_since != before_value, 'needs_review_since should be updated'

        # Verify application updates
        assert @application.income_proof.attached?, 'Income proof should be attached'
        assert_equal 'not_reviewed', @application.income_proof_status
        assert_not_nil @application.needs_review_since

        # Verify both events were created (similar to integration test)
        attachment_events = Event.where(action: 'income_proof_attached').order(created_at: :desc)
        tracking_events = Event.where(action: 'proof_submitted').order(created_at: :desc)

        assert_equal 1, attachment_events.count, 'Expected 1 income_proof_attached event'
        assert_equal 1, tracking_events.count, 'Expected 1 proof_submitted event'

        # Check the tracking event (from controller)
        tracking_event = tracking_events.first
        assert_equal 'proof_submitted', tracking_event.action
        assert_equal @application.id, tracking_event.auditable_id
        assert_equal 'Application', tracking_event.auditable_type
        assert_equal @user.id, tracking_event.user_id
        assert_equal 'income', tracking_event.metadata['proof_type']
        assert_equal 'web', tracking_event.metadata['submission_method']
        assert_equal '127.0.0.1', tracking_event.metadata['ip_address']
        assert_equal 'Rails Testing', tracking_event.metadata['user_agent']

        # Check the attachment event (from ProofAttachmentService)
        attachment_event = attachment_events.first
        assert_equal 'income_proof_attached', attachment_event.action
        assert_equal @user.id, attachment_event.user_id
        assert_equal @application.id, attachment_event.auditable_id
        assert_equal 'income', attachment_event.metadata['proof_type']
      end
    end
  end

  # test 'cannot submit proof if not rejected' do
  #   # Set up a non-rejected application
  #   @application.income_proof.attach(io: StringIO.new('dummy content'), filename: 'dummy.pdf', content_type: 'application/pdf')
  #   @application.update!(income_proof_status: :not_reviewed)

  #   # Remove all stubs - rely on controller filters and application state
  #   # ensure_can_submit_proof should pass (can_submit_proof? is true by default)
  #   # authorize_proof_access! should fail can_modify_proof? and redirect/halt

  #   # Make the request
  #   post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
  #        params: { proof_type: 'income', income_proof: @valid_pdf }

  #   # Verify the redirect from authorize_proof_access!
  #   assert_redirected_to constituent_portal_application_path(@application)
  #   # Check the flash directly after the redirect is asserted
  #   assert_equal 'Invalid proof type or status', flash[:alert]
  # end
  # The application already includes before_action :authenticate_user! in all controllers
  # through the Application controller, which we've tested elsewhere

  test 'resubmit handles rate limit exceeded' do
    # Unskipped - fixed authentication issues

    # Mock the RateLimit.check! method to raise an exception
    RateLimit.stubs(:check!).raises(RateLimit::ExceededError.new('Rate limit exceeded'))

    # The request should not raise an exception because the controller handles it
    post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
         params: { proof_type: 'income', income_proof: @valid_pdf }

    # The controller redirects to the application path with an alert
    assert_redirected_to constituent_portal_application_path(@application)
    assert_equal 'Please wait before submitting another proof', flash[:alert]
  end

  test 'resubmit handles general errors' do
    # Unskipped - fixed authentication issues

    # Mock the attach_and_update_proof method to raise an exception
    ConstituentPortal::Proofs::ProofsController.any_instance.stubs(:attach_and_update_proof).raises(StandardError.new('Test error'))

    # This should raise an exception because we're purposely testing error handling
    assert_raises StandardError do
      post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
           params: { proof_type: 'income', income_proof: @valid_pdf }
    end
  end

  test 'can access dependent application for proof submission' do
    # Create a dependent user
    dependent = create(:constituent, :with_address_and_phone)
    
    create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

    # Create an application for the dependent with rejected income proof
    dependent_application = create(:application, :paper_rejected_proofs, user: dependent)
  
    # Guardian should be able to submit proof for dependent's application
    assert_difference 'Event.count', 2 do
      post "/constituent_portal/applications/#{dependent_application.id}/proofs/resubmit",
           params: { proof_type: 'income', income_proof: @valid_pdf }
    end
  
    # Verify redirect and flash
    assert_redirected_to constituent_portal_application_path(dependent_application)
    assert_equal 'Proof submitted successfully', flash[:notice]
  
    # Verify the dependent's application was updated
    dependent_application.reload
    assert dependent_application.income_proof.attached?
    assert_equal 'not_reviewed', dependent_application.income_proof_status
  end

  test 'proof upload help shows the program phone number' do
    get constituent_portal_application_new_proof_path(application_id: @application.id, proof_type: 'income')

    assert_response :success
    assert_includes response.body, "or call #{ProgramContact.support_phone}."
  end

  test 'an application the constituent cannot reach redirects to the dashboard' do
    other_application = create(:application, :paper_rejected_proofs)

    get constituent_portal_application_new_proof_path(application_id: other_application.id, proof_type: 'income')

    assert_redirected_to constituent_portal_dashboard_path
    assert_equal 'Application not found', flash[:alert]
  end

  test 'a refused upload returns to the form with an actionable message and changes nothing' do
    header = "%PDF-1.4\n"
    oversized = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(header + ('x' * (ProofUploadFormats::PROOF_MAX_BYTES + 1 - header.bytesize))),
      filename: 'large.pdf', content_type: 'application/pdf'
    )

    assert_no_difference -> { Event.where(auditable: @application, action: 'proof_submitted').count } do
      post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
           params: { proof_type: 'income', income_proof: oversized.signed_id }
    end

    assert_response :unprocessable_content
    assert_equal I18n.t('documents.refused.too_large',
                        max_size: ProofUploadFormats.max_megabytes(:proof)), flash[:alert]
    assert_predicate @application.reload, :income_proof_status_rejected?
    # An oversized upload is not reusable, so the form offers no retained document
    assert_select 'input[name="income_proof_signed_id"]', count: 0
    assert_select 'input[type="file"][name="income_proof"]'
  end

  test 'a refused upload keeps an earlier usable upload for the next attempt' do
    usable = ActiveStorage::Blob.create_and_upload!(
      io: file_fixture('income_proof.pdf').open, filename: 'income_proof.pdf', content_type: 'application/pdf'
    )

    post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
         params: { proof_type: 'income', income_proof: fixture_file_upload('invalid.exe', 'application/octet-stream'),
                   income_proof_signed_id: usable.signed_id }

    assert_response :unprocessable_content
    assert_equal I18n.t('documents.refused.invalid_type'), flash[:alert]
    assert_select "input[name='income_proof_signed_id'][value='#{usable.signed_id}']"
    assert_select 'p[role="status"]', text: I18n.t('documents.upload.uploaded', filename: 'income_proof.pdf')

    post "/constituent_portal/applications/#{@application.id}/proofs/resubmit",
         params: { proof_type: 'income', income_proof_signed_id: usable.signed_id }

    assert_redirected_to constituent_portal_application_path(@application)
    assert_equal usable, @application.reload.income_proof.blob
  end
end
