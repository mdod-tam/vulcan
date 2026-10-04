# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @user = create(:constituent, :with_disabilities)
      sign_in_for_integration_test(@user)
    end

    test 'should get show' do
      get constituent_portal_dashboard_path
      assert_response :success
    end

    test 'dashboard shows correct application status for constituent' do
      create(:application, user: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success
      assert_select 'div.flex.items-center span.rounded-full', text: 'In progress'
    end

    test 'dashboard shows awaiting-proof status and details link' do
      create(:application, user: @user, status: :awaiting_proof)

      get constituent_portal_dashboard_path
      assert_response :success
      assert_select 'div.flex.items-center span.rounded-full', text: 'Awaiting proof'
      assert_select 'a', text: 'View Application Details'
    end

    test 'dashboard shows apply for dependent info when no dependents exist with no active application' do
      get constituent_portal_dashboard_path
      assert_response :success

      assert_select 'a', text: 'Apply for Myself'

      assert_select 'h4', text: 'Want to apply for a dependent?'
      assert_select 'p', text: 'You must first add dependents to your account before applying on their behalf.'
      assert_select 'a', text: 'Add a Dependent'

      assert_select 'a', text: 'Apply for a Dependent', count: 0
    end

    test 'dashboard shows apply for dependent button when dependents exist with no active application' do
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

      get constituent_portal_dashboard_path
      assert_response :success

      assert_select 'a', text: 'Apply for Myself'

      assert_select 'a', text: "Apply for #{dependent.full_name}"

      assert_select 'a', text: 'Add Another Dependent'
    end

    test 'dashboard shows apply for dependent info when no dependents exist with active application' do
      create(:application, user: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success

      assert_select 'a', text: 'View Application Details'

      assert_select 'h4', text: 'Want to apply for a dependent?'
      assert_select 'p', text: 'You must first add dependents to your account before applying on their behalf.'
      assert_select 'a', text: 'Add a Dependent'

      assert_select 'a', text: 'Apply for a Dependent', count: 0
    end

    test 'dashboard shows apply for dependent button when dependents exist with active application' do
      create(:application, user: @user, status: :in_progress)

      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

      get constituent_portal_dashboard_path
      assert_response :success

      assert_select 'a', text: 'View Application Details'

      assert_select 'a', text: "Apply for #{dependent.full_name}"

      assert_select 'a', text: 'Add Another Dependent'
    end

    test 'dashboard shows view dependent application when dependent has active application' do
      create(:application, user: @user, status: :in_progress)

      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

      create(:application, user: dependent, managing_guardian: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success

      assert_select 'a', text: 'View Application Details'

      assert_select 'a', text: "View #{dependent.full_name}'s Application"

      assert_select 'a', text: "Apply for #{dependent.full_name}", count: 0

      assert_select 'a', text: 'Add Another Dependent'
    end

    test 'dashboard shows correct buttons in dependents section based on application status' do
      dependent_with_app = create(:constituent, first_name: 'Sally', last_name: 'Black')
      dependent_without_app = create(:constituent, first_name: 'John', last_name: 'Doe')

      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent_with_app)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent_without_app)

      create(:application, user: dependent_with_app, managing_guardian: @user, status: :in_progress)

      get constituent_portal_dashboard_path
      assert_response :success

      assert_select 'a', text: 'View Application'

      assert_select 'a', text: 'Start Application'
    end

    test 'dashboard handles case where user has no personal application but has dependent applications' do
      dependent = create(:constituent, :with_disabilities)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)

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

    test 'dashboard shows completed training session notes as a constituent refresher' do
      application = create_reviewed_application(user: @user)
      product = create(:product, name: 'Clarity Alto')
      create(:training_session,
             :completed,
             application: application,
             trainer: create(:trainer, first_name: 'Trainer', last_name: 'Person'),
             product_trained_on: product,
             notes: 'Reviewed volume controls and saving frequent contacts.')

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select '[data-testid="training-card"]' do
        assert_select 'h4', text: 'Previous Sessions'
        assert_select 'p', text: 'What we covered'
        assert_select 'p', text: 'Reviewed volume controls and saving frequent contacts.'
        assert_select 'span', text: 'Clarity Alto'
      end
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
