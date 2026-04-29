# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsQueuesTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'training_requests queue renders the queue-oriented table with applicant, app id, requested date, status, and view action' do
      app = create(:application, :completed, training_requested_at: 1.second.ago,
                                             user: create(:constituent, speech_disability: true))

      get admin_applications_path(filter: 'training_requests')
      assert_response :success

      assert_select 'div[data-testid=training-requests-queue]'
      body = @response.body
      assert_includes body, app.user.full_name
      assert_includes body, "##{app.id}"
      assert_match(/Awaiting Assignment|Needs Scheduling/, body)
      assert_match(/View Application/, body)
    end

    test 'training_requests queue does not infer pending state from notifications' do
      app = create(:application, :completed, user: create(:constituent, speech_disability: true))
      Notification.create!(
        action: 'training_requested',
        notifiable: app,
        recipient: @admin,
        actor: app.user,
        metadata: { application_id: app.id }
      )
      # Do NOT set training_requested_at.

      get admin_applications_path(filter: 'training_requests')
      assert_response :success
      assert_select "#training_request_row_#{app.id}", count: 0
    end

    test 'evaluation_requests queue surfaces only explicit pending requests' do
      pending_app = create(:application, :completed, evaluation_requested_at: 1.second.ago,
                                                     user: create(:constituent, speech_disability: true))

      quiet_app = create(:application, :completed, user: create(:constituent, speech_disability: true))

      get admin_applications_path(filter: 'evaluation_requests')
      assert_response :success

      assert_select 'div[data-testid=evaluation-requests-queue]'
      assert_includes @response.body, "##{pending_app.id}"
      assert_not_includes @response.body, "##{quiet_app.id}"
    end
  end
end
