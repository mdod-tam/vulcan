# frozen_string_literal: true

require 'test_helper'

class GuardianApplicationFlowTest < ActionDispatch::IntegrationTest
  setup do
    # Setup a verified guardian user
    @guardian = create(:constituent, email: 'guardian@example.com', verified: true, email_verified: true)

    # Use the proper integration test helper to sign in
    sign_in_for_integration_test(@guardian)

    # Now directly GET the dashboard (don't expect a redirect)
    get constituent_portal_dashboard_path
    assert_response :success
  end

  test 'guardian can access dashboard' do
    # Visit dashboard page
    get constituent_portal_dashboard_path
    assert_response :success
    assert_select 'h1', /Dashboard/
  end

  test 'guardian can create dependent' do
    # Get the new dependent form
    get new_constituent_portal_dependent_path
    assert_response :success

    # Submit the form with valid parameters including unique phone
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

    # Verify redirect to dashboard
    assert_redirected_to constituent_portal_dashboard_path
  end

  test 'guardian can apply on behalf of a minor or dependent' do
    # ----- Arrange: create a dependent and the relationship -----
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

    # ----- Act: navigate through the UI flow -----
    # Visit dashboard to start
    get constituent_portal_dashboard_path
    assert_response :success

    # Verify dashboard has the button/link for dependent application
    # The view shows specific links for each dependent, not a generic "Apply for a Dependent" link
    assert_select 'a[href=?]', new_constituent_portal_application_path(user_id: dependent.id, for_self: false), text: "Apply for #{dependent.full_name}"

    # Navigate to the new application form for the dependent
    get new_constituent_portal_application_path(for_self: false)
    assert_response :success

    # Verify the form has a section for selecting the dependent
    assert_select "select[name='application[user_id]']"

    # ----- Submit the form with all required parameters -----
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

    # Verify redirection after submission
    assert_redirected_to constituent_portal_application_path(Application.last)

    # ----- Assert: the application was created with correct attributes -----
    application = Application.last
    assert_equal dependent.id, application.user_id, 'Application should belong to the dependent'
    assert_equal @guardian.id, application.managing_guardian_id, 'Guardian should be set as the managing guardian'
    # application.vision_disability is not a direct column - check self_certify_disability instead
    assert application.self_certify_disability, 'Disability should be self-certified'
    assert_equal 4, application.household_size, 'Household size should be set correctly'
    assert_equal 50_000, application.annual_income, 'Annual income should be set correctly'
  end

  test 'dependent applications appear on guardian dashboard' do
    # Create a dependent
    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    dependent = create(:constituent, first_name: 'Dependent', last_name: 'Child', phone: unique_phone)

    # Create the guardian relationship
    GuardianRelationship.create!(
      guardian_user: @guardian,
      dependent_user: dependent,
      relationship_type: 'Parent'
    )

    # Create an application for the dependent managed by the guardian
    application = create(:application,
                         user: dependent,
                         managing_guardian: @guardian,
                         status: 'in_progress')

    # Visit the dashboard
    get constituent_portal_dashboard_path
    assert_response :success

    # Verify the dependent's application appears
    assert_select 'a[href=?]', constituent_portal_application_path(application)
    assert_select 'td', text: dependent.full_name
  end

  test 'guardian can create new application for dependent even if orphaned application exists (Bug #6)' do
    # This tests the fix for Bug #6: orphaned applications without managing_guardian_id
    # should not block creation of new applications by the current guardian

    # Create a dependent
    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    dependent = create(:constituent, first_name: 'Dependent', last_name: 'Child', phone: unique_phone)

    # Create the guardian relationship
    GuardianRelationship.create!(
      guardian_user: @guardian,
      dependent_user: dependent,
      relationship_type: 'Parent'
    )

    # Create an orphaned application (no managing_guardian_id set)
    # This simulates a bug where applications were created without the guardian link
    orphaned_app = create(:application,
                          :archived, # archived so it doesn't show as active
                          user: dependent,
                          managing_guardian: nil) # Orphaned!

    # Core test: Navigate to new application form - should NOT redirect to orphaned app
    # With strict ownership model, orphaned app is not accessible by guardian
    get new_constituent_portal_application_path(user_id: dependent.id, for_self: false)
    assert_response :success, 'Should allow creating new application, not redirect to orphaned app'

    # Should be able to create a new application despite orphaned app existing
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

    # Verify the new application has the correct managing_guardian_id
    new_app = Application.last
    assert_equal dependent.id, new_app.user_id
    assert_equal @guardian.id, new_app.managing_guardian_id, 'New application should link to current guardian'
    assert_not_equal orphaned_app.id, new_app.id, 'Should create a new application, not update the orphaned one'

    # Verify guardian can access the new app
    assert new_app.accessible_by?(@guardian), 'Guardian should be able to access their managed application'

    # NOTE: The orphaned app will have managing_guardian_id auto-set by the before_save callback
    # when a guardian relationship exists. This is expected behavior that helps recover from
    # data inconsistencies. The key test is that we could create a NEW application despite
    # the orphaned app existing (which our strict ownership model allows).
  end
end
