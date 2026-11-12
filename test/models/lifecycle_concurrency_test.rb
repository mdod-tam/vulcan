# frozen_string_literal: true

require 'test_helper'
require_relative '../support/concurrency_test_helper'

class LifecycleConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ConcurrencyTestHelper
  include ActiveJob::TestHelper

  setup do
    Current.reset
    clear_enqueued_jobs
    @extra_users = []
    @admin = create(:admin)
    @user = create(:constituent, :with_disabilities)
  end

  teardown do
    Current.reset
    cleanup_duplicate_review_test_data!(@admin, @user, *@extra_users)
    clear_enqueued_jobs
  end

  test 'competing evaluation requests recheck pending state after the same application lock' do
    application = create(:application, :completed, user: @user)
    signals = Queue.new
    workers = []
    Application.transaction do
      application.lock!
      blocker = backend_pid
      2.times do
        worker = on_own_connection do
          signals << backend_pid
          begin
            Application.find(application.id).request_evaluation!(actor: @admin)
            :accepted
          rescue ArgumentError
            :duplicate
          end
        end
        workers << worker
        pid = wait_for_signal(signals, thread: worker)
        wait_until_blocked_on_lock(pid, blocked_by: blocker, thread: worker)
        blocker = pid
      end
    end
    assert_equal %i[accepted duplicate], workers.map(&:value).sort
    assert_equal 1, application.events.where(action: 'evaluation_requested').count
    assert application.reload.evaluation_requested_at
  ensure
    workers&.each { |worker| reap_thread(worker, timeout: 10, suppress_errors: $ERROR_INFO.present?) }
  end

  test 'competing live assignments serialize and keep one open evaluation' do
    application = create(:application, :completed, user: @user, application_date: Date.current)
    actors = [@admin, create(:admin)]
    evaluators = create_list(:evaluator, 2)
    @extra_users.push(actors.last, *evaluators)
    signals = Queue.new
    workers = []
    Application.transaction do
      application.lock!
      blocker = backend_pid
      actors.zip(evaluators).each do |actor, evaluator|
        worker = on_own_connection do
          signals << backend_pid
          Applications::EvaluatorAssignment.assign(Application.find(application.id), evaluator, actor: actor)
        end
        workers << worker
        pid = wait_for_signal(signals, thread: worker)
        wait_until_blocked_on_lock(pid, blocked_by: blocker, thread: worker)
        blocker = pid
      end
    end
    assert workers.map(&:value).all?(&:success?)
    assert_equal 1, application.evaluations.open_assigned.count
  ensure
    workers&.each { |worker| reap_thread(worker, timeout: 10, suppress_errors: $ERROR_INFO.present?) }
  end

  test 'cleanup rechecks activity after waiting on a refreshed session row' do
    session = Session.create!(user: @user, ip_address: '127.0.0.1', user_agent: 'cleanup race',
                              last_active_at: (Session::IDLE_TIMEOUT + 1.minute).ago, expires_at: 1.hour.from_now)
    signals = Queue.new
    worker = nil
    Session.transaction do
      session.lock!
      session.update!(last_active_at: Time.current)
      holder = backend_pid
      worker = on_own_connection do
        signals << backend_pid
        CleanupExpiredSessionsJob.perform_now
      end
      wait_until_blocked_on_lock(wait_for_signal(signals), blocked_by: holder)
    end
    worker.value
    assert Session.exists?(session.id)
    assert_not session.reload.expired?
  ensure
    reap_thread(worker, timeout: 10, suppress_errors: $ERROR_INFO.present?) if worker
  end
end
