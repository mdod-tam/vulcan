# frozen_string_literal: true

require 'test_helper'

module Admin
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    def setup
      # Use factory and standard helper for authentication
      @admin = create(:admin)
      sign_in_as(@admin)

      # Create applications with different statuses for testing
      @draft_app = create(:application, :draft, user: create(:constituent, email: "draft#{@admin.email}"))
      @in_progress_app = create(:application, :in_progress, user: create(:constituent, email: "in_progress#{@admin.email}"))
      @approved_app = create(:application, :approved, user: create(:constituent, email: "approved#{@admin.email}"))

      # Create applications with proofs needing review
      @app_with_income_proof = create(:application, :in_progress, user: create(:constituent, email: "income_proof#{@admin.email}"))
      @app_with_income_proof.income_proof.attach(
        io: Rails.root.join('test/fixtures/files/income_proof.pdf').open,
        filename: 'income_proof.pdf',
        content_type: 'application/pdf'
      )
      # Use correct enum value :not_reviewed instead of :pending
      @app_with_income_proof.update!(income_proof_status: :not_reviewed)

      email = "residency_proof#{@admin.email}"
      @app_with_residency_proof = create(:application, :in_progress, user: create(:constituent, email: email))
      @app_with_residency_proof.residency_proof.attach(
        io: Rails.root.join('test/fixtures/files/residency_proof.pdf').open,
        filename: 'residency_proof.pdf',
        content_type: 'application/pdf'
      )
      # Use correct enum value :not_reviewed instead of :pending
      @app_with_residency_proof.update!(residency_proof_status: :not_reviewed)

      # Create application with medical certification received
      email = "medical_cert#{@admin.email}"
      @app_with_medical_cert = create(:application, :in_progress, user: create(:constituent, email: email))
      @app_with_medical_cert.medical_certification.attach(
        io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
        filename: 'medical_certification_valid.pdf',
        content_type: 'application/pdf'
      )
      @app_with_medical_cert.update!(medical_certification_status: :received)

      # Skip training request for now since the columns don't exist in the database
      # @app_with_training = create(:application, :in_progress)
      # @app_with_training.user.update!(training_requested: true, training_completed: false)
    end

    def test_index_calculates_correct_counts
      setup_initial_training_request

      # First dashboard request: verify proofs and medical certs counts
      # Dashboard redirects to admin/applications#index, so follow the redirect
      get admin_dashboard_path
      assert_redirected_to admin_applications_path
      follow_redirect!
      assert_response :success
      verify_dashboard_counts

      setup_training_requests

      # Second dashboard request: verify training requests count
      get admin_dashboard_path
      assert_redirected_to admin_applications_path
      follow_redirect!
      assert_response :success
      verify_training_request_counts
    end

    def test_filter_by_proofs_needing_review
      get admin_applications_path, params: { filter: 'proofs_needing_review' }
      assert_response :success

      # Verify that only applications with not_reviewed proofs are included
      applications = assigns(:applications)
      assert_not_empty applications, 'Expected applications needing proof review, but found none.'
      applications.each do |app|
        assert(
          app.income_proof_status_not_reviewed? || app.residency_proof_status_not_reviewed?,
          "Application #{app.id} (status: #{app.status}, income: #{app.income_proof_status}, residency: #{app.residency_proof_status}) does not have a proof needing review"
        )
      end
    end

    def test_filter_by_medical_certs_to_review
      get admin_applications_path, params: { filter: 'medical_certs_to_review' }
      assert_response :success

      # Verify that only applications with received medical certifications are included
      applications = assigns(:applications)
      applications.each do |app|
        assert_equal 'received', app.medical_certification_status,
                     "Application #{app.id} does not have a received medical certification"
      end
    end

    def test_filter_by_training_requests
      # Explicitly create an application with a unique ID and user
      constituent = create(:constituent, email: "training_user_#{Time.now.to_i}@example.com")
      application = create(:application, :approved, user: constituent)

      # Store the application ID before creating the notification
      application_id = application.id

      # Create a notification explicitly relating to this application
      NotificationService.create_and_deliver!(
        type: 'training_requested',
        recipient: @admin,
        actor: application.user,
        notifiable: application
      )

      # Now let's try the actual controller logic
      controller = Admin::DashboardController.new
      controller.params = { filter: 'training_requests' }
      controller.request = @request

      # Verify the filter directly
      get admin_applications_path, params: { filter: 'training_requests' }
      assert_response :success

      apps = assigns(:applications)

      assert_includes apps.map(&:id), application_id,
                      "Application #{application_id} should be included in the filtered results"
    end

    def teardown
      Current.reset if defined?(Current) && Current.respond_to?(:reset)
    end

    private

    def setup_initial_training_request
      # Create one training request notification so the dashboard has data for non-training counts.
      application = create(:application, :approved)
      NotificationService.create_and_deliver!(
        type: 'training_requested',
        recipient: @admin,
        actor: application.user,
        notifiable: application
      )
    end

    def verify_dashboard_counts
      # Verify counts for proofs needing review.
      expected_proofs_count = Application.where(income_proof_status: :not_reviewed)
                                         .or(Application.where(residency_proof_status: :not_reviewed))
                                         .count
      # Access metrics hash.
      assert_equal expected_proofs_count, assigns(:metrics)[:proofs_needing_review_count],
                   'Expected proofs needing review count to match'

      # Verify counts for medical certifications.
      expected_medical_certs_count = Application.where(medical_certification_status: 'received').count
      assert_equal expected_medical_certs_count, assigns(:metrics)[:medical_certs_to_review_count],
                   'Expected medical certificates to review count to match'
    end

    def setup_training_requests
      # Clear any existing training request notifications to start fresh.
      Notification.where(action: 'training_requested').delete_all

      # Create exactly 4 training request notifications with unique applications.
      4.times do |i|
        application = create(:application, :approved,
                             user: create(:constituent, email: "training#{i}@example.com"))
        # No assignment is required here.
        NotificationService.create_and_deliver!(
          type: 'training_requested',
          recipient: @admin,
          actor: application.user,
          notifiable: application
        )
      end
    end

    def verify_training_request_counts
      distinct_apps_count = Notification.where(action: 'training_requested')
                                        .where(notifiable_type: 'Application')
                                        .distinct.count(:notifiable_id)

      assert_equal 4, distinct_apps_count,
                   'Database should have 4 distinct applications with training requests'
      assert_equal 4, assigns(:metrics)[:training_requests_count],
                   'Controller should assign 4 training requests'
    end
  end
end
