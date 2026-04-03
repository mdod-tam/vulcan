# frozen_string_literal: true

require 'test_helper'

module Admin
  class ScannedProofsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin = create(:admin)
      email = "constituent#{@admin.email}"
      @application = create(:application, user: create(:constituent, email: email))
      @file = fixture_file_upload(
        Rails.root.join('test/fixtures/files/test_proof.pdf'),
        'application/pdf'
      )

      # Use our enhanced sign_in helper
      sign_in_as(@admin) # Use standard helper
    end

    def test_rejects_invalid_proof_types
      get new_admin_application_scanned_proof_path(@application, proof_type: 'invalid'),
          headers: default_headers
      assert_redirected_to admin_application_path(@application)
      assert_flash_message(:alert, 'Invalid proof type')
    end

    def test_creates_proof_with_valid_parameters
      # Clear events before the test to ensure we only count events from this test
      Event.delete_all
      clear_enqueued_jobs

      assert_no_difference -> { Notification.where(notifiable: @application, action: 'income_proof_attached').count } do
        assert_no_difference -> { Notification.where(notifiable: @application, action: 'proof_submitted').count } do
          assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
            assert_difference 'Event.count', 1 do # Controller creates one proof_submitted event; service audit event is skipped
              post admin_application_scanned_proofs_path(@application),
                   params: {
                     proof_type: 'income',
                     file: @file
                   },
                   headers: default_headers
            end
          end
        end
      end

      @application.reload

      # Verify the application has the proof attached first
      assert @application.income_proof.attached?, 'Proof was not attached to the application'
      assert_equal 'approved', @application.income_proof_status
      assert_nil @application.needs_review_since, 'Approved scanned proofs should not set needs_review_since'

      # Verify the redirect
      assert_redirected_to admin_application_path(@application)

      # Verify the audit event was created correctly
      event = Event.last
      assert_equal 'proof_submitted', event.action
      assert_equal @application.id, event.auditable_id
      assert_equal 'Application', event.auditable_type
      assert_equal @admin.id, event.user_id
      assert_equal 'income', event.metadata['proof_type']
      assert_equal 'paper', event.metadata['submission_method']
      assert_equal true, event.metadata['success']
      assert_not_nil event.metadata['blob_id']
      assert_equal @file.original_filename, event.metadata['filename']
    end

    def test_handles_missing_files
      post admin_application_scanned_proofs_path(@application),
           params: { proof_type: 'income' },
           headers: default_headers
      assert_redirected_to new_admin_application_scanned_proof_path(@application)
      assert_flash_message(:alert, 'Please select a file to upload')
    end

    def test_requires_authentication
      delete sign_out_path
      get new_admin_application_scanned_proof_path(@application, proof_type: 'income'),
          headers: { 'Accept' => 'application/json' }
      assert_redirected_to sign_in_path
    end
  end
end
