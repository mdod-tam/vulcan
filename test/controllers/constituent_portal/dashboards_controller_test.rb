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

    test 'dashboard keeps accessible personal and managed applications separate from an inaccessible personal application' do
      personal_application = create(:application, user: @user, created_at: 2.days.ago)
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @user)
      inaccessible_application = create(:application, user: @user, managing_guardian: guardian, created_at: 1.day.ago)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)
      managed_application = create(:application, user: dependent, managing_guardian: @user)

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'section[aria-labelledby="my-application-status-title"]' do
        assert_select 'a[href=?]', constituent_portal_application_path(personal_application), text: 'View Application Details'
        assert_select 'a[href=?]', constituent_portal_application_path(managed_application), count: 0
      end
      assert_select 'section[aria-labelledby="managed-applications-title"]' do
        assert_select 'a[href=?]', constituent_portal_application_path(managed_application),
                      text: "View #{dependent.full_name}'s Application"
      end
      assert_select 'a[href=?]', constituent_portal_application_path(inaccessible_application), count: 0
      assert_select 'h3', text: 'My Guardians'
      assert_select 'p', text: guardian.full_name
    end

    test 'dashboard omits a personal draft managed by another guardian while keeping the guardian continuation link' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @user)
      draft = create(:application, :draft, user: @user, managing_guardian: guardian)

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'section[aria-labelledby="my-application-status-title"]' do
        assert_select 'p', text: 'No active application found.'
        assert_select 'a', text: 'Apply for Myself'
        assert_select 'a', text: 'Continue Unsubmitted Application', count: 0
      end
      assert_select 'a[href=?]', edit_constituent_portal_application_path(draft), count: 0
      assert_select 'h3', text: 'My Guardians'
      assert_select 'p', text: guardian.full_name

      sign_in_for_integration_test(guardian)
      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'section[aria-labelledby="managed-applications-title"]' do
        assert_select 'a[href=?]', edit_constituent_portal_application_path(draft), text: "Continue #{@user.full_name}'s Draft"
      end
    end

    test 'dashboard keeps personal and managed draft continuation links on their own cards' do
      personal_draft = create(:application, :draft, user: @user, created_at: 1.day.ago)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)
      managed_draft = create(:application, :draft, user: dependent, managing_guardian: @user)

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'section[aria-labelledby="my-application-status-title"]' do
        assert_select 'a[href=?]', edit_constituent_portal_application_path(personal_draft), text: 'Continue Unsubmitted Application'
        assert_select 'a[href=?]', edit_constituent_portal_application_path(managed_draft), count: 0
      end
      assert_select 'section[aria-labelledby="managed-applications-title"]' do
        assert_select 'a[href=?]', edit_constituent_portal_application_path(managed_draft), text: "Continue #{dependent.full_name}'s Draft"
      end
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

    test 'dashboard shows only the deliberately shared completed training summary' do
      application = create_reviewed_application(user: @user)
      product = create(:product, name: 'Clarity Alto')
      session = create(:training_session,
                       :completed,
                       application: application,
                       trainer: create(:trainer, first_name: 'Trainer', last_name: 'Person'),
                       product_trained_on: product,
                       internal_notes: 'PRIVATE STAFF OBSERVATIONS 9137',
                       constituent_summary: 'Reviewed volume controls and saving frequent contacts.', summary_locale: 'es')

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select '[data-testid="training-card"]' do
        assert_select 'h4', text: 'Previous Sessions'
        assert_select 'p', text: 'What we covered'
        assert_select 'p', text: 'Reviewed volume controls and saving frequent contacts.'
        assert_select 'span', text: 'Clarity Alto'
        assert_select 'p[lang=es]', text: 'Reviewed volume controls and saving frequent contacts.'
        assert_select 'a', text: 'Read summary and product resources'
      end
      assert_not_includes response.body, 'PRIVATE STAFF OBSERVATIONS 9137'

      get constituent_portal_training_session_path(session)
      assert_response :success
      assert_includes response.body, session.constituent_summary
    end

    test 'dashboard and completed report both exclude a managed applicant from the shared summary' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @user)
      application = create(:application, :approved, :with_all_proofs, user: @user, managing_guardian: guardian)
      session = create(:training_session, :completed, application: application,
                                                      constituent_summary: 'MANAGED REPORT SUMMARY 6273')

      get constituent_portal_training_session_path(session)
      assert_response :not_found

      get constituent_portal_dashboard_path
      assert_response :success
      assert_not_includes response.body, session.constituent_summary
      assert_select 'a[href=?]', constituent_portal_training_session_path(session), count: 0
      assert_select 'a[href=?]', constituent_portal_application_path(application), count: 0
      assert_select '[data-testid="training-card"]', count: 0
      assert_select 'section[aria-labelledby="my-application-status-title"] p', text: 'No active application found.'
      assert_select 'h3', text: 'My Guardians'
      assert_select 'p', text: guardian.full_name

      sign_in_for_integration_test(guardian)
      get constituent_portal_dashboard_path
      assert_response :success
      assert_select 'a[href=?]', constituent_portal_application_path(application), text: "View #{@user.full_name}'s Application"

      get constituent_portal_training_session_path(session)
      assert_response :success
      assert_includes response.body, session.constituent_summary
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
