# frozen_string_literal: true

require 'test_helper'

module Admin
  module Icanconnect
    class SettingsControllerTest < ActionDispatch::IntegrationTest
      include IcanconnectTestSupport

      test 'only an admin can set the iCanConnect start date' do
        sign_in_as(create(:constituent), bypass_mfa_enrollment: true)
        assert_no_difference('::Icanconnect::Setting.count') do
          patch admin_icanconnect_settings_path, params: { icanconnect_setting: { starts_on: '12/01/2026' } }
        end
        assert_response :redirect
      end

      test 'setting and clearing the start date is audited with both values' do
        start_icanconnect!(on: nil)
        admin = create(:admin)
        sign_in_as(admin, bypass_mfa_enrollment: true)
        date = '12/01/2026'
        patch admin_icanconnect_settings_path, params: { icanconnect_setting: { starts_on: date } }
        assert_redirected_to admin_policies_path(anchor: 'icanconnect-participation')
        setting = ::Icanconnect::Setting.sole
        assert_equal Date.new(2026, 12, 1), setting.starts_on

        patch admin_icanconnect_settings_path, params: { icanconnect_setting: { starts_on: '' } }
        assert_redirected_to admin_policies_path(anchor: 'icanconnect-participation')
        assert_nil setting.reload.starts_on
        events = Event.where(auditable: setting, action: 'icanconnect_start_date_updated').order(:id)
        assert_equal [admin.id, admin.id], events.pluck(:user_id)
        changes = events.map { |event| event.metadata.fetch('changes').fetch('starts_on') }
        assert_equal [[nil, '2026-12-01'], ['2026-12-01', nil]], changes
      end
    end
  end
end
