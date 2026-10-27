# frozen_string_literal: true

require 'test_helper'

module Admin
  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin_david = create(:admin, email: 'david@example.com', first_name: 'David')
    end

    def test_should_get_index
      sign_in_as(@admin_david)
      get admin_root_path
      assert_response :success
    end
  end
end
