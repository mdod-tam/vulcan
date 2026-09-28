# frozen_string_literal: true

require 'test_helper'
require 'timeout'

class NotificationDeliveryConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    DatabaseCleaner.clean
    @threads = []
    @release_route = Queue.new
    @user = create(:constituent)
    @notification = Notification.create!(recipient: @user, notifiable: @user, action: 'w9_approved',
                                         metadata: { 'temp_password' => '[REDACTED]', 'workflow' => 'preserved' })
    @request_id = SecureRandom.uuid
  end

  teardown do
    @release_route << true
    @threads.each { |thread| thread.join(10) || thread.kill }
    Event.where("metadata->>'request_id' = ?", @request_id).delete_all
    @notification&.destroy!
    @user&.destroy!
  end

  %i[suppressed configuration_error].each do |outcome|
    test "routing preserves #{outcome} written before it acquires the row" do
      stale = Notification.find(@notification.id)
      write_outcome(outcome)

      persist_route(stale)

      assert_outcome(outcome)
    end

    test "#{outcome} waits for the routing lock and wins after routing commits" do
      read_ready = Queue.new
      start_routing_writer(read_ready)
      Timeout.timeout(5) { read_ready.pop }
      worker_pid = Queue.new
      @threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          worker_pid << connection.select_value('SELECT pg_backend_pid()')
          write_outcome(outcome)
        end
      end
      pid = Timeout.timeout(5) { worker_pid.pop }

      assert_worker_blocked(pid)
      @release_route << true
      @threads.each { |thread| Timeout.timeout(10) { thread.value } }

      assert_outcome(outcome)
    end
  end

  private

  def persist_route(notification)
    NotificationService.new.send(:persist_delivery_routing_metadata, notification,
                                 actual_delivery_channel: 'email', delivery_route_reason: 'requested_channel')
  end

  # Pause at the actual metadata read, with or without the implementation's row lock.
  def start_routing_writer(read_ready)
    notification_id = @notification.id
    release = @release_route
    @threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        notification = Notification.find(notification_id)
        notification.define_singleton_method(:metadata) do
          value = super()
          unless @paused_for_routing
            @paused_for_routing = true
            read_ready << true
            Timeout.timeout(10) { release.pop }
          end
          value
        end
        persist_route(notification)
      end
    end
  end

  def assert_worker_blocked(pid)
    Timeout.timeout(5) do
      loop do
        blocked = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)})) > 0")
        end
        break if blocked

        flunk 'worker completed through an unlocked routing read/write window' unless @threads.last.alive?
        Thread.pass
      end
    end
  end

  def write_outcome(outcome)
    decision = EmailDelivery::Decision.public_send(outcome, 'test_reason')
    EmailDelivery::Outcome.record_not_sent(decision, context: { 'notification_id' => @notification.id, 'request_id' => @request_id },
                                                     mail_action: 'VendorNotificationsMailer#w9_approved')
  end

  def assert_outcome(outcome)
    @notification.reload
    assert_equal(outcome == :suppressed ? 'suppressed' : 'error', @notification.delivery_status)
    assert_equal 'none', @notification.metadata['actual_delivery_channel']
    key = outcome == :suppressed ? 'delivery_suppressed' : 'delivery_error'
    assert_equal 'test_reason', @notification.metadata.dig(key, 'reason')
    assert_equal '[REDACTED]', @notification.metadata['temp_password']
    assert_equal 'preserved', @notification.metadata['workflow']
  end
end
