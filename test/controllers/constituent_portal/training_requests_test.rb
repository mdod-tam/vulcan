# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/notification_delivery_stub'

module ConstituentPortal
  class TrainingRequestsTest < ActionDispatch::IntegrationTest
    setup do
      @constituent = create(:constituent)
      @admin = create(:admin)

      @application = create(:application, user: @constituent, application_date: 2.years.ago.to_date)

      Current.user = @admin
      @application.update!(status: :approved)
      Current.reset

      Policy.find_or_create_by(key: 'max_training_sessions').update(value: 3)

      sign_in_for_integration_test(@constituent)

      Current.user = @constituent
    end

    teardown do
      Current.reset
    end

    test 'should create training request notification' do
      ConstituentPortal::ApplicationsController.any_instance.stubs(:log_training_request).returns(nil)

      admin_count = User.where(type: ['Administrator', 'Users::Administrator']).count

      # These mocks verify calls to NotificationService. They do not prove notification persistence.
      NotificationService.expects(:create_and_deliver!).with(
        type: 'training_requested',
        recipient: anything,
        actor: anything,
        notifiable: anything,
        metadata: anything,
        channel: :email
      ).times(admin_count).returns(nil)

      post request_training_constituent_portal_application_path(@application)

      assert_redirected_to constituent_portal_dashboard_path
      assert_equal 'Training request submitted. An administrator will contact you to schedule your session.',
                   flash[:notice]
    end

    test 'should not create training request if application not approved' do
      Current.user = @admin
      @application.update!(status: :in_progress)
      Current.reset

      assert_no_difference 'Notification.count' do
        post request_training_constituent_portal_application_path(@application)
      end

      assert_redirected_to constituent_portal_dashboard_path
      assert_equal 'Only approved applications are eligible for training.', flash[:alert]
    end

    test 'should not create training request if max sessions reached' do
      trainer = create(:trainer)

      3.times do |i|
        TrainingSession.create!(
          application: @application,
          trainer: trainer,
          scheduled_for: 1.day.from_now,
          status: :completed,
          notes: "Training session #{i + 1} completed successfully",
          completed_at: Time.current
        )
      end

      ConstituentPortal::ApplicationsController.any_instance.stubs(:log_training_request).returns(nil)

      assert_no_difference 'Notification.count' do
        post request_training_constituent_portal_application_path(@application)
      end

      assert_redirected_to constituent_portal_dashboard_path
      assert_equal 'You have used all of your available training sessions.', flash[:alert]
    end
  end
end
