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
  end
end
