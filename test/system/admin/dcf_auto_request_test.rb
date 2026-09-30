# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class DcfAutoRequestTest < ApplicationSystemTestCase
    test 'admin enables and disables future DCF requests with an audit trail' do
      admin = create(:admin)
      flag = FeatureFlag.find_or_create_by!(name: 'dcf_auto_request_certification') { |row| row.enabled = false }
      sign_in(admin)
      visit admin_feature_flags_path
      within('[data-feature-flag="dcf_auto_request_certification"]') do
        assert_text 'Existing applications awaiting DCF are unchanged.'
        click_button 'Enable'
      end
      assert_text 'Feature flag updated successfully'
      assert flag.reload.enabled
      assert Event.exists?(action: 'feature_flag_toggled', auditable: flag, user: admin)
      take_screenshot('dcf-auto-request-enabled', html: true)
      within('[data-feature-flag="dcf_auto_request_certification"]') { click_button 'Disable' }
      assert_text 'Feature flag updated successfully'
      assert_not flag.reload.enabled
      assert_equal 2, Event.where(action: 'feature_flag_toggled', auditable: flag).count
      take_screenshot('dcf-auto-request-disabled', html: true)
    end

    test 'a refused auto-request remains visible on the application' do
      admin = create(:admin)
      application = create(:application, :in_progress)
      application.transition_status!(:awaiting_dcf, actor: admin, metadata: { dcf_auto_request: true })
      sign_in(admin)
      visit admin_application_path(application)
      assert_text 'Auto-send not sent — request manually.'
      find_by_id('certification-title').scroll_to(:center)
      take_screenshot('dcf-auto-request-not-sent', html: true)
    end
  end
end
