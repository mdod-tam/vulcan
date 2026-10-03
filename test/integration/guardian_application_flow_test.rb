# frozen_string_literal: true

require 'test_helper'

class GuardianApplicationFlowTest < ActionDispatch::IntegrationTest
  setup do
    @guardian = create(:constituent, email: 'guardian@example.com', verified: true, email_verified: true)

    sign_in_for_integration_test(@guardian)

    get constituent_portal_dashboard_path
    assert_response :success
  end

  test 'guardian can access dashboard' do
    get constituent_portal_dashboard_path
    assert_response :success
    assert_select 'h1', /Dashboard/
  end

  test 'guardian can create dependent' do
    get new_constituent_portal_dependent_path
    assert_response :success

    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    assert_difference -> { @guardian.dependents.count } do
      post constituent_portal_dependents_path, params: {
        dependent: {
          first_name: 'Dependent',
          last_name: 'Child',
          email: 'dependent_child@example.com',
          phone: unique_phone,
          date_of_birth: 10.years.ago.to_date,
          vision_disability: true
        },
        guardian_relationship: {
          relationship_type: 'Parent'
        }
      }
    end

    assert_redirected_to constituent_portal_dashboard_path
  end

  test 'guardian can apply on behalf of a minor or dependent' do
    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    dependent = create(
      :constituent,
      first_name: 'Dependent',
      last_name: 'Child',
      email: 'dependent_child@example.com',
      phone: unique_phone,
      date_of_birth: 10.years.ago.to_date
    )

    GuardianRelationship.create!(
      guardian_user: @guardian,
      dependent_user: dependent,
      relationship_type: 'Parent'
    )

    get constituent_portal_dashboard_path
    assert_response :success

    # The dashboard has one link per dependent, not a generic "Apply for a Dependent" link.
    assert_select 'a[href=?]', new_constituent_portal_application_path(user_id: dependent.id, for_self: false), text: "Apply for #{dependent.full_name}"

    get new_constituent_portal_application_path(user_id: dependent.id, for_self: false)
    assert_response :success

    assert_select 'span.font-semibold', text: dependent.full_name

    assert_difference -> { Application.count } do
      post constituent_portal_applications_path, params: {
        application: {
          user_id: dependent.id, # This is how the form identifies the dependent
          maryland_resident: true,
          household_size: 4,
          annual_income: 50_000,
          self_certify_disability: true,
          vision_disability: true,
          medical_provider_name: 'Dr. Test',
          medical_provider_phone: '123-456-7890',
          medical_provider_email: 'doctor@example.com',
          submit_application: true # Simulate clicking the Submit Application button
        }
      }
    end

    assert_redirected_to constituent_portal_application_path(Application.last)

    application = Application.last
    assert_equal dependent.id, application.user_id, 'Application should belong to the dependent'
    assert_equal @guardian.id, application.managing_guardian_id, 'Guardian should be set as the managing guardian'
    # vision_disability is not an Application column.
    assert application.self_certify_disability, 'Disability should be self-certified'
    assert_equal 4, application.household_size, 'Household size should be set correctly'
    assert_equal 50_000, application.annual_income, 'Annual income should be set correctly'
  end

  test 'dependent applications appear on guardian dashboard' do
    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    dependent = create(:constituent, first_name: 'Dependent', last_name: 'Child', phone: unique_phone)

    GuardianRelationship.create!(
      guardian_user: @guardian,
      dependent_user: dependent,
      relationship_type: 'Parent'
    )

    application = create(:application,
                         user: dependent,
                         managing_guardian: @guardian,
                         status: 'in_progress')

    get constituent_portal_dashboard_path
    assert_response :success

    assert_select 'a[href=?]', constituent_portal_application_path(application)
    assert_select 'td', text: dependent.full_name
  end

  test 'guardian can create new application for dependent even if orphaned application exists (Bug #6)' do
    # Bug #6: an application without managing_guardian_id must not block a new application by the
    # current guardian.
    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    dependent = create(:constituent, first_name: 'Dependent', last_name: 'Child', phone: unique_phone)

    GuardianRelationship.create!(
      guardian_user: @guardian,
      dependent_user: dependent,
      relationship_type: 'Parent'
    )

    # Application#ensure_managing_guardian_set assigns @guardian from the relationship above at
    # create, so this record is not actually orphaned when the test runs.
    orphaned_app = create(:application,
                          :archived, # archived so it doesn't show as active
                          user: dependent,
                          managing_guardian: nil)

    get new_constituent_portal_application_path(user_id: dependent.id, for_self: false)
    assert_response :success, 'Should allow creating new application, not redirect to orphaned app'

    assert_difference -> { Application.count } do
      post constituent_portal_applications_path, params: {
        application: {
          user_id: dependent.id,
          maryland_resident: true,
          household_size: 3,
          annual_income: 40_000,
          self_certify_disability: true,
          vision_disability: true,
          medical_provider_name: 'Dr. Smith',
          medical_provider_phone: '555-1234',
          medical_provider_email: 'smith@example.com'
        },
        save_draft: true
      }
    end

    new_app = Application.last
    assert_equal dependent.id, new_app.user_id
    assert_equal @guardian.id, new_app.managing_guardian_id, 'New application should link to current guardian'
    assert_not_equal orphaned_app.id, new_app.id, 'Should create a new application, not update the orphaned one'

    assert new_app.accessible_by?(@guardian), 'Guardian should be able to access their managed application'
  end
end
