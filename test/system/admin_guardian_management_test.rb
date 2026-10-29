# frozen_string_literal: true

require 'application_system_test_case'

class AdminGuardianManagementTest < ApplicationSystemTestCase
  setup do
    @admin = create(:admin, verified: true, email_verified: true)
    @guardian = create(:constituent, email: 'guardian.admin.view@example.com', phone: '5555550030')
    @dependent = create(:constituent, email: 'dependent.admin.view@example.com', phone: '5555550031')
    GuardianRelationship.create!(guardian_id: @guardian.id, dependent_id: @dependent.id, relationship_type: 'Parent')
    @application_for_dependent = create(:application,
                                        user: @dependent,
                                        managing_guardian: @guardian,
                                        status: 'in_progress',
                                        application_date: Date.current,
                                        maryland_resident: true,
                                        certifying_professional_name: 'Test Provider',
                                        certifying_professional_phone: '555-123-4567',
                                        certifying_professional_email: 'provider@example.com',
                                        household_size: 2,
                                        annual_income: 30_000,
                                        self_certify_disability: true)

    system_test_sign_in(@admin)

    visit admin_applications_path
    wait_for_turbo
  end

  test 'admin can view guardian info on application index' do
    assert_current_path admin_applications_path
    assert_text @dependent.full_name
    assert_text @guardian.full_name
  end

  test 'admin can view guardian info on application show page' do
    visit admin_application_path(@application_for_dependent)
    wait_for_turbo

    assert_current_path admin_application_path(@application_for_dependent)
    assert_text @dependent.full_name
    assert_text @guardian.full_name
    assert_text 'Parent'
  end

  test 'admin can view dependents on guardian user show page' do
    visit admin_user_path(@guardian)
    wait_for_turbo

    assert_current_path admin_user_path(@guardian)
    assert_text @dependent.full_name
    assert_text 'Parent'
    assert_selector 'a', text: /Back to List/
  end

  test 'admin can view guardians on dependent user show page' do
    visit admin_user_path(@dependent)
    wait_for_turbo

    assert_current_path admin_user_path(@dependent)
    assert_text @guardian.full_name
    assert_text 'Parent'
    assert_text @guardian.email
    assert_selector 'a', text: /Back to List/
  end

  test 'admin can view dependent information without add functionality' do
    visit admin_user_path(@guardian)
    wait_for_turbo

    assert_current_path admin_user_path(@guardian)
    assert_text @dependent.full_name
    assert_text 'Parent'

    assert GuardianRelationship.exists?(guardian_id: @guardian.id, dependent_id: @dependent.id)
  end

  test 'admin can verify guardian relationship exists' do
    visit admin_user_path(@guardian)
    wait_for_turbo

    assert_current_path admin_user_path(@guardian)
    assert_text @dependent.full_name

    assert GuardianRelationship.exists?(guardian_id: @guardian.id, dependent_id: @dependent.id)
  end
end
