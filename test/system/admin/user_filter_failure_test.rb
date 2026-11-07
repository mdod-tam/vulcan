# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  # The filter form updates only the users_list frame, so a failed filter must warn inside that frame.
  # Integration tests send the Turbo-Frame header but cannot show the browser replacing the frame.
  class UserFilterFailureTest < ApplicationSystemTestCase
    test 'a failed filter warns inside the results frame, and the next filter clears the warning' do
      warning = I18n.t('alerts.unfiltered_error')
      system_test_sign_in(create(:admin))
      visit admin_users_path
      assert_selector 'turbo-frame#users_list'
      assert_no_selector "[role='alert']", text: warning

      Users::FilterService.any_instance.stubs(:build_filtered_scope).raises(StandardError, 'forced filter failure')
      select 'Constituent', from: 'role'

      assert_selector "turbo-frame#users_list [role='alert']", text: warning
      assert_selector "[role='alert']", text: warning, count: 1
      take_screenshot('admin-users-filter-failure-warning', html: true)

      Users::FilterService.any_instance.unstub(:build_filtered_scope)
      select 'Evaluator', from: 'role'

      assert_no_selector "[role='alert']", text: warning
      assert_selector 'turbo-frame#users_list'
    end
  end
end
