# frozen_string_literal: true

require 'test_helper'

module Admin
  class DashboardControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin = create(:admin)
      sign_in_as(@admin)
      Rails.cache.clear

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

    def test_dashboard_still_reports_proof_and_medical_review_metrics
      get admin_dashboard_path
      assert_response :success

      expected_proofs_count = Application.where(income_proof_status: :not_reviewed)
                                         .or(Application.where(residency_proof_status: :not_reviewed))
                                         .count
      expected_medical_certs_count = Application.where(medical_certification_status: 'received').count

      assert_equal expected_proofs_count, assigns(:metrics)[:proofs_needing_review_count]
      assert_equal expected_medical_certs_count, assigns(:metrics)[:medical_certs_to_review_count]
    end

    def test_filter_by_proofs_needing_review
      get admin_applications_path, params: { filter: 'proofs_needing_review' }
      assert_response :success

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

      applications = assigns(:applications)
      applications.each do |app|
        assert_equal 'received', app.medical_certification_status,
                     "Application #{app.id} does not have a received medical certification"
      end
    end

    def test_dashboard_count_matches_pending_training_request_filter
      pending_request = create_reviewed_application(user: create(:constituent, email: 'dashboard_pending_training@example.com'))
      pending_request.update!(training_requested_at: 1.hour.ago)

      fulfilled_request = create_reviewed_application(user: create(:constituent, email: 'dashboard_fulfilled_training@example.com'))
      fulfilled_request.update!(training_requested_at: 2.hours.ago)
      create(:training_session, application: fulfilled_request, trainer: create(:trainer), status: :requested)

      notification_only = create_reviewed_application(user: create(:constituent, email: 'dashboard_notification_only@example.com'))
      create(:notification,
             recipient: @admin,
             actor: notification_only.user,
             notifiable: notification_only,
             action: 'training_requested')

      get admin_dashboard_path
      assert_response :success
      dashboard_count = assigns(:metrics)[:training_requests_count]

      get admin_applications_path, params: { filter: 'training_requests' }
      assert_response :success

      apps = assigns(:applications)

      assert_equal 1, dashboard_count
      assert_includes apps.map(&:id), pending_request.id
      assert_not_includes apps.map(&:id), fulfilled_request.id
      assert_not_includes apps.map(&:id), notification_only.id
      assert_equal dashboard_count, apps.size
    end

    def teardown
      Rails.cache.clear
      Current.reset if defined?(Current) && Current.respond_to?(:reset)
      Rails.cache.clear
    end

    private

    def create_reviewed_application(user:)
      application = create(:application, skip_proofs: true, user: user, status: :in_progress)
      application.income_proof.attach(
        io: StringIO.new('income proof content'),
        filename: 'income.pdf',
        content_type: 'application/pdf'
      )
      application.residency_proof.attach(
        io: StringIO.new('residency proof content'),
        filename: 'residency.pdf',
        content_type: 'application/pdf'
      )
      application.update_columns(
        status: Application.statuses[:approved],
        income_proof_status: Application.income_proof_statuses[:approved],
        residency_proof_status: Application.residency_proof_statuses[:approved],
        medical_certification_status: Application.medical_certification_statuses[:approved],
        updated_at: Time.current
      )
      application.reload
    end
  end
end
