# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationAnalyticsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'should get pain_points' do
      create(:application, status: :draft, last_visited_step: 'step_1')
      create(:application, status: :draft, last_visited_step: 'step_1')
      create(:application, status: :draft, last_visited_step: 'step_2')

      get admin_application_analytics_pain_points_url

      assert_response :success
      assert_not_nil assigns(:analysis_results)

      expected_results = {
        'step_1' => 2,
        'step_2' => 1
      }
      assert_equal expected_results, assigns(:analysis_results)
    end

    test 'should handle no pain point data' do
      get admin_application_analytics_pain_points_url
      assert_response :success
      assert_equal({}, assigns(:analysis_results))
    end
  end
end
