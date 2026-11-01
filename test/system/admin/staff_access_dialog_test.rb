# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class StaffAccessDialogTest < ApplicationSystemTestCase
    setup do
      @evaluator = create(:evaluator)
      @grant = create(:role_capability, user: @evaluator, capability: 'can_train')
      @session = create(:training_session, :scheduled, trainer: @evaluator)
      @checkbox = "capability_can_train_#{@evaluator.id}"
      @dialog = "#staff_access_dialog_#{@evaluator.id}"
      system_test_sign_in(create(:admin))
      install_stimulus_error_reporting
      visit admin_users_path(q: @evaluator.email)
    end

    test 'removing access that strands open work asks first, and Cancel keeps the access' do
      uncheck @checkbox

      within @dialog do
        assert_text "#{@evaluator.full_name} has 1 active training session. Removing training access sends them to Training needing reassignment."
        take_screenshot('admin-staff-access-confirmation', html: true)
        click_button 'Cancel'
      end

      assert_no_selector 'dialog[open]'
      assert_checked_field @checkbox
      assert RoleCapability.exists?(@grant.id)
      assert_equal @evaluator.id, @session.reload.trainer_id
    end

    test 'a stale confirmation answers 422, keeps the dialog open with fresh impact, and applies only when confirmed again' do
      uncheck @checkbox
      assert_selector "#{@dialog}[open]"

      create(:training_session, :no_show, application: @session.application, trainer: @evaluator)
      within(@dialog) { click_button 'Continue' }

      within @dialog do
        assert_text 'This access changed or the confirmation expired. Review the current work and confirm again.'
        assert_text "#{@evaluator.full_name} has 2 active training sessions."
      end
      assert RoleCapability.exists?(@grant.id)

      within(@dialog) { click_button 'Continue' }

      assert_no_selector 'dialog[open]'
      assert_not RoleCapability.exists?(@grant.id)
      assert_equal [@evaluator.id], @session.application.training_sessions.reload.map(&:trainer_id).uniq
      assert_unchecked_field @checkbox
    end

    test 'deactivation and reactivation preserve history while ending the users sessions' do
      user_session = create_test_session(@evaluator)
      click_link @evaluator.full_name
      assert_selector 'h1', text: "User Details: #{@evaluator.full_name}"

      dismiss_confirm { click_button 'Deactivate User' }
      assert_button 'Deactivate User'
      assert @evaluator.reload.active?
      assert Session.exists?(user_session.id)
      take_screenshot('admin-user-deactivation-cancelled', html: true, full: true)

      accept_confirm { click_button 'Deactivate User' }
      assert_text 'User deactivated. History was preserved and sessions were revoked.'
      assert_button 'Reactivate User'
      assert @evaluator.reload.inactive?
      assert_not Session.exists?(user_session.id)
      assert_equal @evaluator.id, @session.reload.trainer_id
      assert RoleCapability.exists?(@grant.id)
      take_screenshot('admin-user-deactivated-history-retained', html: true, full: true)

      click_button 'Reactivate User'
      assert_text 'User reactivated. The user can sign in again.'
      assert_button 'Deactivate User'
      assert @evaluator.reload.active?
      assert_not Session.exists?(user_session.id)
      take_screenshot('admin-user-reactivated', html: true, full: true)
    end
  end
end
