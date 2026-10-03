# frozen_string_literal: true

require 'application_system_test_case'

class ProofUploadsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @user = create(:constituent, email_verified: true, verified: true)
    @valid_pdf = file_fixture('income_proof.pdf')

    # Create application with rejected proofs using factory
    @application = create(
      :application,
      :in_progress_with_rejected_proofs,
      user: @user,
      status: :awaiting_proof
    )

    # Verify prerequisites
    assert @application.income_proof.attached?, 'Income proof must be attached'
    assert @application.income_proof_status_rejected?, 'Income proof status must be rejected'
    assert_equal @application.user_id, @user.id, 'Application should belong to test user'

    # Set up rate limit policies required by proof submission
    Policy.find_or_create_by!(key: 'proof_submission_rate_limit_web') { |p| p.value = 10 }
    Policy.find_or_create_by!(key: 'proof_submission_rate_period') { |p| p.value = 24 }

    # Sign in using documented pattern
    system_test_sign_in(@user)
    assert_authenticated_as(@user)
  end

  test 'constituent can view proof upload form' do
    path = constituent_portal_application_new_proof_path(@application, proof_type: 'income')
    visit path
    wait_for_turbo

    assert_selector 'h1', text: 'Upload New Income Proof'
    assert_selector "[data-controller='document-upload']"
    assert_field 'income_proof', type: 'file'
    assert_button 'Submit Document'
    assert_text 'Maximum file size: 5MB'
  end

  test 'constituent can resubmit rejected proof from application page' do
    visit "/constituent_portal/applications/#{@application.id}"
    assert_text 'Application Details'

    # Rejected proofs show a Resubmit button
    assert_text 'Resubmit Income Proof'

    click_on 'Resubmit Income Proof'
    assert_selector 'h1', text: /Upload New Income Proof/i

    attach_file 'income_proof', @valid_pdf
    click_button 'Submit Document'

    assert_success_message('Proof submitted successfully')
    assert_current_path constituent_portal_application_path(@application)
  end

  test 'prevents resubmitting when proof is not rejected' do
    @application.update!(income_proof_status: :not_reviewed)
    visit "/constituent_portal/applications/#{@application.id}"
    assert_text 'Application Details'
    assert_no_text 'Resubmit Income Proof'
  end

  test 'requires authentication for proof submission' do
    click_on 'Sign Out', match: :first
    visit "/constituent_portal/applications/#{@application.id}"
    assert_current_path '/sign_in'
  end

  test 'constituent can upload proof document' do
    visit constituent_portal_application_new_proof_path(@application, proof_type: 'income')
    wait_for_turbo

    attach_file 'income_proof', @valid_pdf
    assert_text I18n.t('documents.upload.selected', filename: 'income_proof.pdf')

    # The file uploads when the form is submitted
    click_button 'Submit Document'
    wait_for_turbo

    # Should redirect to success page or dashboard
    assert_success_message('Proof submitted successfully')

    # Verify proof was attached
    assert @application.reload.income_proof.attached?
  end

  test 'cancelling an upload before the file is stored keeps the form usable and a new submit succeeds' do
    # Hold the first blob-creation request so Cancel lands before any storage request exists
    browser = page.driver.browser
    held_requests = Queue.new
    hold_next = true
    browser.network.intercept(pattern: '*/rails/active_storage/direct_uploads*')
    browser.on(:request) do |request|
      if hold_next
        hold_next = false
        held_requests << request
      else
        request.continue
      end
    end

    visit constituent_portal_application_new_proof_path(@application, proof_type: 'income')
    wait_for_turbo

    attach_file 'income_proof', @valid_pdf
    click_button 'Submit Document'
    held_request = held_requests.pop(timeout: 10)
    assert held_request, 'the blob-creation request should be held'
    assert_text I18n.t('documents.upload.uploading', filename: 'income_proof.pdf')

    click_button I18n.t('documents.upload.cancel')
    assert_text I18n.t('documents.upload.canceled')
    assert_no_button I18n.t('documents.upload.cancel')
    assert_no_selector "[data-document-upload-target='progress']", visible: true

    begin
      held_request.continue
    rescue Ferrum::Error
      # The browser already dropped the aborted request
    end
    assert_current_path constituent_portal_application_new_proof_path(@application, proof_type: 'income')
    assert_predicate @application.reload, :income_proof_status_rejected?

    click_button 'Submit Document'
    wait_for_turbo

    assert_success_message('Proof submitted successfully')
    assert @application.reload.income_proof.attached?
  end

  test 'shows error for invalid file type' do
    visit constituent_portal_application_new_proof_path(@application, proof_type: 'income')
    wait_for_turbo

    attach_file 'income_proof', file_fixture('invalid.exe')

    assert_text I18n.t('documents.refused.invalid_type')
  end

  test 'shows error for oversized file' do
    # Create a large file temporarily for this test
    large_file = Tempfile.new(['large_proof', '.pdf'])
    large_file.write('x' * 6.megabytes) # Create 6MB file (over 5MB limit)
    large_file.close

    visit constituent_portal_application_new_proof_path(@application, proof_type: 'income')
    wait_for_turbo

    attach_file 'income_proof', large_file.path

    assert_text I18n.t('documents.refused.too_large', max_size: 5)

    large_file.unlink # Clean up
  end
end
