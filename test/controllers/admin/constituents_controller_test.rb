# frozen_string_literal: true

require 'test_helper'

module Admin
  class ConstituentsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @constituent = create(:constituent)
      sign_in_for_integration_test(create(:admin), bypass_mfa_enrollment: true)
    end

    test 'type lookup returns a constituent identity and does not expose a different STI role or missing identity' do
      get type_check_admin_constituents_path, params: { email: @constituent.email }
      assert_response :success
      assert_equal({ 'id' => @constituent.id, 'type' => 'Users::Constituent', 'class' => 'Users::Constituent' }, response.parsed_body)

      vendor = create(:vendor)
      [vendor.email, 'missing-constituent@example.test'].each do |email|
        get type_check_admin_constituents_path, params: { email: email }
        assert_response :not_found
        assert_equal({ 'error' => 'Constituent not found' }, response.parsed_body)
      end
    end

    test 'a constituent cannot query the admin type lookup' do
      sign_in_for_integration_test(@constituent)
      get type_check_admin_constituents_path, params: { email: @constituent.email }
      assert_redirected_to root_path
      assert_not_includes response.body, 'Users::Constituent'
    end
  end
end
