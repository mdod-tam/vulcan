# frozen_string_literal: true

require 'test_helper'

# The live Postmark polling path for medical certification request notifications.
class UpdateEmailStatusJobTest < ActiveJob::TestCase
  setup do
    @admin = create(:admin)
    @application = create(:application)
    @notification = Notification.create!(
      recipient: @admin, actor: @admin, action: 'medical_certification_requested', notifiable: @application,
      message_id: 'pm-123', metadata: { 'channel' => 'email' }
    )
  end

  test 'Postmark Sent and Processed mean the provider has the message, not recipient delivery' do
    %w[Sent Processed].each do |raw|
      @notification.update!(delivery_status: nil)
      poll(status: raw)

      @notification.reload
      assert_equal 'submitted', @notification.delivery_status, raw
      assert_equal raw, @notification.metadata['provider_status']
      assert_nil @notification.email_error_message
    end
  end

  test 'Postmark Queued is recorded as queued' do
    poll(status: 'Queued')

    assert_equal 'queued', @notification.reload.delivery_status
  end

  test 'delivery and open timestamps set delivered and opened, and a later poll does not move backward' do
    delivered_at = 2.hours.ago.change(usec: 0)
    poll(status: 'Sent', delivered_at: delivered_at)
    assert_equal 'delivered', @notification.reload.delivery_status

    opened_at = 1.hour.ago.change(usec: 0)
    poll(status: 'Sent', delivered_at: delivered_at, opened_at: opened_at, open_details: { 'Client' => { 'Name' => 'Mail' } })
    poll(status: 'Sent')

    @notification.reload
    assert_equal 'opened', @notification.delivery_status
    assert_equal opened_at, @notification.opened_at
    assert_equal 'Mail', @notification.metadata.dig('email_details', 'Client', 'Name')
  end

  test 'an unrecognized provider status is kept visible without inventing a delivery status' do
    poll(status: 'Mystery')

    @notification.reload
    assert_nil @notification.delivery_status
    assert @notification.metadata['provider_status_unrecognized']
    assert_equal 'Mystery', @notification.metadata['provider_status']
  end

  test 'a tracker failure is not recorded as a delivery failure and is checked again later' do
    assert_enqueued_with(job: UpdateEmailStatusJob) { poll(status: 'error') }

    @notification.reload
    assert_nil @notification.delivery_status
    assert @notification.metadata['status_check_failed_at'].present?
  end

  test 'a suppressed notification is not polled or overwritten' do
    @notification.mark_delivery_suppressed!('global_disabled')
    PostmarkEmailTracker.expects(:fetch_status).never

    UpdateEmailStatusJob.perform_now(@notification.id)

    assert_equal 'suppressed', @notification.reload.delivery_status
  end

  test 'a processing error stays readable, even when metadata is nil' do
    @notification.update_columns(metadata: nil)
    PostmarkEmailTracker.stubs(:fetch_status).raises(StandardError, 'Postmark timeout')

    assert_nothing_raised { UpdateEmailStatusJob.perform_now(@notification.id) }

    @notification.reload
    assert_equal 'error', @notification.delivery_status
    assert_equal 'Postmark timeout', @notification.email_error_message
  end

  test 'a processing error keeps unrelated metadata' do
    PostmarkEmailTracker.stubs(:fetch_status).raises(StandardError, 'Postmark timeout')

    UpdateEmailStatusJob.perform_now(@notification.id)

    @notification.reload
    assert_equal 'email', @notification.metadata['channel']
    assert_equal 'Postmark timeout', @notification.email_error_message
  end

  test 'the certification history status badge renders for a tracked notification' do
    @notification.update!(delivery_status: 'submitted')

    badge = ApplicationController.helpers.delivery_status_badge(@notification)

    assert_includes badge, 'submitted'
  end

  private

  def poll(status:, delivered_at: nil, opened_at: nil, open_details: nil)
    PostmarkEmailTracker.stubs(:fetch_status).returns(
      { status: status, delivered_at: delivered_at, opened_at: opened_at, open_details: open_details }
    )
    UpdateEmailStatusJob.perform_now(@notification.id)
  ensure
    PostmarkEmailTracker.unstub(:fetch_status)
  end
end
