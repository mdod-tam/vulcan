# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper # Ensure helper methods are available

    setup do
      @user = create(:constituent, :with_disabilities) # Use the :constituent factory
      sign_in_for_integration_test(@user) # Use helper for integration tests
    end

    test 'should get show' do
      # Assuming the dashboard show page is the root for the constituent portal
      get constituent_portal_dashboard_path
      assert_response :success
    end

    test 'dashboard shows correct application status for constituent' do
      create(:application, user: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success
      # Assert for the status badge text using a more specific selector
      assert_select 'div.flex.items-center span.rounded-full', text: 'In progress'
    end

    test 'dashboard shows different content based on application status' do
      # Test for a status that might require user action, e.g., awaiting_proof
      create(:application, user: @user, status: :awaiting_proof)

      get constituent_portal_dashboard_path
      assert_response :success
      # Assert for the status badge text and the view details link
      assert_select 'div.flex.items-center span.rounded-full', text: 'Awaiting proof'
      assert_select 'a', text: 'View Application Details'
    end

    test 'dashboard shows apply for dependent info when no dependents exist with no active application' do
      # Ensure user has no dependents and no active application
      get constituent_portal_dashboard_path
      assert_response :success

      # Should show "Apply for Myself" button
      assert_select 'a', text: 'Apply for Myself'

      # Should show the "Want to apply for a dependent?" info box
      assert_select 'h4', text: 'Want to apply for a dependent?'
      assert_select 'p', text: 'You must first add dependents to your account before applying on their behalf.'
      assert_select 'a', text: 'Add a Dependent'

      # Should not show the "Apply for a Dependent" button
      assert_select 'a', text: 'Apply for a Dependent', count: 0
    end

    test 'dashboard shows apply for dependent button when dependents exist with no active application' do
      # Create a dependent for the user
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

      get constituent_portal_dashboard_path
      assert_response :success

      # Should show "Apply for Myself" button
      assert_select 'a', text: 'Apply for Myself'

      # Should show the "Apply for [Dependent Name]" button (personalized)
      assert_select 'a', text: "Apply for #{dependent.full_name}"

      # Should show "Add Another Dependent" button
      assert_select 'a', text: 'Add Another Dependent'
    end

    test 'dashboard shows apply for dependent info when no dependents exist with active application' do
      # Create an active application for the user
      create(:application, user: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success

      # Should show "View Application Details" button
      assert_select 'a', text: 'View Application Details'

      # Should show the "Want to apply for a dependent?" info box
      assert_select 'h4', text: 'Want to apply for a dependent?'
      assert_select 'p', text: 'You must first add dependents to your account before applying on their behalf.'
      assert_select 'a', text: 'Add a Dependent'

      # Should not show the "Apply for a Dependent" button
      assert_select 'a', text: 'Apply for a Dependent', count: 0
    end

    test 'dashboard shows apply for dependent button when dependents exist with active application' do
      # Create an active application for the user
      create(:application, user: @user, status: :in_progress)

      # Create a dependent for the user
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

      get constituent_portal_dashboard_path
      assert_response :success

      # Should show "View Application Details" button
      assert_select 'a', text: 'View Application Details'

      # Should show the "Apply for [Dependent Name]" button (personalized)
      assert_select 'a', text: "Apply for #{dependent.full_name}"

      # Should show "Add Another Dependent" button
      assert_select 'a', text: 'Add Another Dependent'
    end

    test 'dashboard shows view dependent application when dependent has active application' do
      # Create an active application for the user
      create(:application, user: @user, status: :in_progress)

      # Create a dependent for the user
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

      # Create an active application for the dependent
      create(:application, user: dependent, managing_guardian: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success

      # Should show "View Application Details" button for user's own application
      assert_select 'a', text: 'View Application Details'

      # Should show "View [Dependent Name]'s Application" button instead of "Apply for"
      assert_select 'a', text: "View #{dependent.full_name}'s Application"

      # Should NOT show "Apply for [Dependent Name]" button
      assert_select 'a', text: "Apply for #{dependent.full_name}", count: 0

      # Should show "Add Another Dependent" button
      assert_select 'a', text: 'Add Another Dependent'
    end

    test 'dashboard shows correct buttons in dependents section based on application status' do
      # Create a dependent for the user
      dependent_with_app = create(:constituent, first_name: 'Sally', last_name: 'Black')
      dependent_without_app = create(:constituent, first_name: 'John', last_name: 'Doe')

      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent_with_app)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent_without_app)

      # Create an active application for one dependent
      create(:application, user: dependent_with_app, managing_guardian: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success

      # Should show "View Application" for dependent with app
      assert_select 'a', text: 'View Application'

      # Should show "Start Application" for dependent without app
      assert_select 'a', text: 'Start Application'
    end

    test 'dashboard handles case where user has no personal application but has dependent applications' do
      # Create a dependent for the user
      dependent = create(:constituent, :with_disabilities)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

      # Create an active application for the dependent (but not for the user)
      create(:application, user: dependent, managing_guardian: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success

      assert_select 'h3', text: 'My Application'
      assert_select 'a', text: 'Apply for Myself'
      assert_select 'a', text: "View #{dependent.full_name}'s Application"

      assert_select 'a', text: 'Add Another Dependent'
    end

    test 'dashboard shows requested training state and disables duplicate request button' do
      application = create_reviewed_application(user: @user)
      application.update!(training_requested_at: 1.hour.ago)

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'button[disabled]', text: 'Training Session Requested'
      assert_select 'p', text: /A trainer will reach out soon/
      assert_select 'form[action=?]', request_training_constituent_portal_application_path(application), count: 0
    end

    test 'dashboard shows active training session state and disables duplicate request button' do
      application = create_reviewed_application(user: @user)
      create(:training_session, application: application, trainer: create(:trainer), status: :requested)

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'button[disabled]', text: 'Training Assigned'
      assert_select 'p', text: /Assigned to/
      assert_select 'form[action=?]', request_training_constituent_portal_application_path(application), count: 0
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
        application_date: 1.year.ago.to_date,
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
