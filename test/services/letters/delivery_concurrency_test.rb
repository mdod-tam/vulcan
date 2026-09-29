# frozen_string_literal: true

require 'test_helper'

module Letters
  class DeliveryConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      @admin = create(:admin)
      @recipient = create(:constituent)
      @application = create(:application, user: @recipient)
      @control = FeatureFlag.find_by!(name: EmailDelivery::ALL_CONTROL)
      @control_before = @control.slice(:enabled, :delivery_generation)
      @context = EmailDelivery::Policy.capture(mail_action: 'Letters#medical_certification_form')
    end

    teardown do
      @control.update_columns(@control_before)
      PrintQueueItem.where(application_id: @application.id).find_each do |item|
        item.pdf_letter.purge
        item.destroy!
      end
      cleanup_duplicate_review_test_data!(@admin, @recipient)
    end

    test 'concurrent rendering of one logical request admits one item and blob' do
      ready = Queue.new
      release = Queue.new
      items = Queue.new
      before_blobs = ActiveStorage::Blob.count
      threads = 2.times.map do
        on_own_connection do
          items << queue do
            ready << true
            release.pop
            StringIO.new('%PDF concurrent')
          end
        end
      end
      threads.each { |thread| wait_for_signal(ready, thread: thread) }
      2.times { release << true }
      threads.each do |thread|
        reap_thread(thread, timeout: 10, suppress_errors: false)
        thread.value
      end

      assert_equal items.pop.id, items.pop.id
      assert_equal 1, PrintQueueItem.where(application_id: @application.id).count
      assert_equal before_blobs + 1, ActiveStorage::Blob.count
    ensure
      threads&.each do |thread|
        release << true
        reap_thread(thread, timeout: 5, suppress_errors: true)
      end
    end

    test 'disable commits before release and the blocked exporter refuses the artifact' do
      item = queue { StringIO.new('%PDF letter') }
      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      refusal = nil
      holder = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          disable
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(holder_ready, thread: holder)
      contender_pid_queue = Queue.new
      contender = on_own_connection do
        contender_pid_queue << backend_pid
        begin
          Delivery.export!([item.id], actor: @admin)
        rescue Delivery::ReleaseDenied => e
          refusal = e
        end
      end
      confirm_blocked_then_release(wait_for_signal(contender_pid_queue, thread: contender), holder_pid: holder_pid,
                                                                                            release_queue: release_holder, holder_thread: holder, contender_thread: contender)
      assert_instance_of Delivery::ReleaseDenied, refusal
      assert_nil item.reload.released_at
      assert item.canceled?
    end

    test 'release commits before disable and remains honest released history' do
      item = queue { StringIO.new('%PDF letter') }
      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      holder = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          Delivery.export!([item.id], actor: @admin)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(holder_ready, thread: holder)
      contender_pid_queue = Queue.new
      contender = on_own_connection do
        contender_pid_queue << backend_pid
        disable
      end
      confirm_blocked_then_release(wait_for_signal(contender_pid_queue, thread: contender), holder_pid: holder_pid,
                                                                                            release_queue: release_holder, holder_thread: holder, contender_thread: contender)
      assert item.reload.released_at
      assert item.pending?
      assert_raises(Delivery::ReleaseDenied) { Delivery.export!([item.id], actor: @admin) }
      assert item.reload.released_at
    end

    private

    def queue(&)
      Delivery.queue!(recipient: User.find(@recipient.id), application: Application.find(@application.id),
                      letter_type: :medical_certification_form, context: @context, actor: @admin, &)
    end

    def disable
      EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: false, actor: @admin, operation_id: SecureRandom.uuid)
    end
  end
end
