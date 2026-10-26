# frozen_string_literal: true

require 'test_helper'

class TestControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create(:admin)
  end

  test 'auth_status should return unauthenticated when not signed in' do
    get test_auth_status_url, headers: { 'Accept' => 'application/json' }
    assert_response :success
    json_response = response.parsed_body
    assert_equal false, json_response['authenticated']
    assert_nil json_response['email']
  end

  test 'auth_status should return authenticated when signed in' do
    sign_in_for_integration_test @admin
    get test_auth_status_url, headers: { 'Accept' => 'application/json' }
    assert_response :success
    json_response = response.parsed_body
    assert_equal true, json_response['authenticated']
    assert_equal @admin.email, json_response['email']
    assert_equal @admin.id, json_response['user_id']
  end
end
