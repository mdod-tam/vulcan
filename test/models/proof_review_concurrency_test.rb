# frozen_string_literal: true

require 'test_helper'

# Inserting a review takes a shared lock on its application row for the foreign key. Counting a rejection
# needs the exclusive lock. Two rejections that each hold the shared lock wait on each other for the
# exclusive one, so record! locks the application before it inserts the review.
class ProofReviewConcurrencyTest < ActiveSupport::TestCase
  include ProofResubmissionTestHelper

  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'concurrent requests with one decision key insert and count only once' do
    admin = create(:admin)
    application = create(:application, :with_income_proof)
    identity = proof_decision_params(application, :income)
    holder_ready = Queue.new
    release_holder = Queue.new
    contender_pid = Queue.new
    outcomes = Queue.new
    holder_thread = on_own_connection do
      decision = ProofReview.record_decision!(application: Application.find(application.id), admin: admin,
                                              proof_type: :income, status: :rejected, rejection_reason: 'Unreadable', **identity) do |review|
        review.record!
        holder_ready << backend_pid
        release_holder.pop
      end
      outcomes << [decision.review.id, decision.recorded]
    end
    holder_pid = wait_for_signal(holder_ready, thread: holder_thread)
    contender_thread = on_own_connection do
      contender_pid << backend_pid
      decision = ProofReview.record_decision!(application: Application.find(application.id), admin: admin,
                                              proof_type: :income, status: :rejected, rejection_reason: 'Unreadable', **identity) do
        raise 'A replay must not enter the decision writer'
      end
      outcomes << [decision.review.id, decision.recorded]
    end
    confirm_blocked_then_release(wait_for_signal(contender_pid, thread: contender_thread), holder_pid: holder_pid,
                                                                                           release_queue: release_holder, holder_thread: holder_thread, contender_thread: contender_thread)

    actual = 2.times.map { outcomes.pop }
    assert_equal 1, actual.map(&:first).uniq.size
    assert_equal [false, true], actual.map(&:last).sort_by(&:to_s)
    assert_equal 1, application.reload.total_rejections
    assert_equal 1, application.proof_reviews.count
  ensure
    cleanup_duplicate_review_test_data!(admin, application&.user)
  end

  test 'a rejection takes the application lock before inserting its review, so concurrent rejections cannot deadlock' do
    admin = create(:admin)
    application = create(:application, :with_income_proof)

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        # A rejection past its insert and about to count: the insert holds the shared lock.
        insert_rejected_review(application, admin, :residency)
        holder_ready << true
        release_holder.pop
        Application.lock.find(application.id)
        Application.where(id: application.id).update_all('total_rejections = total_rejections + 1')
      end
    end
    holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
    wait_for_signal(holder_ready, thread: holder_thread)

    contender_pid_queue = Queue.new
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      record_proof_review(application: Application.find(application.id), proof_type: :income, status: :rejected, admin: admin, rejection_reason: 'Unreadable')
    end

    # The contender waits for the lock before it inserts anything. Once the holder is released, neither waits on the other.
    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert_equal 2, application.reload.total_rejections
    assert_equal %w[income residency], application.proof_reviews.order(:proof_type).map(&:proof_type)
  ensure
    cleanup_duplicate_review_test_data!(admin, application&.user)
  end

  test 'concurrent follow-ups of one archived decision create and queue one constituent notice' do
    admin = create(:admin)
    application = create(:application, :with_income_proof, total_rejections: ProofReview::MAX_REJECTIONS)
    review = record_proof_review(application: application, proof_type: :income, status: :rejected, admin: admin, rejection_reason: 'Unreadable')
    holder_ready = Queue.new
    release_holder = Queue.new
    holder_thread = on_own_connection do
      Application.find(application.id).with_lock do
        holder_ready << backend_pid
        release_holder.pop
      end
    end
    holder_pid = wait_for_signal(holder_ready, thread: holder_thread)
    contender_pids = Queue.new
    contenders = []
    blocked_pids = [holder_pid]
    2.times do
      thread = on_own_connection do
        snapshot = ProofReview.find(review.id)
        # Each live after-commit callback retains the total that this decision recorded.
        snapshot.instance_variable_set(:@rejection_total, review.rejection_total)
        contender_pids << backend_pid
        Applications::ProofDecisionFollowUp.new(snapshot).call
      end
      contenders << thread
      pid = wait_for_signal(contender_pids, thread: thread)
      wait_until_blocked_by_queue(pid, blockers: blocked_pids, thread: thread)
      blocked_pids << pid
    end
    assert_not Notification.exists?(action: 'max_rejections_reached', notifiable: application)
    assert_empty(enqueued_jobs.select { |job| job[:args]&.first(2) == %w[ApplicationNotificationsMailer max_rejections_reached] })
    release_holder << true
    reap_thread(holder_thread, timeout: 10, suppress_errors: false)
    contenders.each { |thread| reap_thread(thread, timeout: 10, suppress_errors: false) }

    notice = Notification.where(action: 'max_rejections_reached', notifiable: application).sole
    jobs = enqueued_jobs.select { |job| job.dig('email_delivery_context', 'notification_id') == notice.id }
    assert_equal 1, jobs.size
    assert_equal 'queued', notice.delivery_status
    assert_predicate application.reload, :status_archived?
  ensure
    release_holder << true if defined?(release_holder)
    threads = [holder_thread, *contenders].compact
    threads.each { |thread| reap_thread(thread, timeout: 10, suppress_errors: true) }
    raise 'Archive notice worker still holds a connection; refusing concurrent cleanup' if threads.any?(&:alive?)

    cleanup_duplicate_review_test_data!(admin, application&.user)
  end

  private

  # PostgreSQL may queue the second row-lock waiter behind the first, rather than the original holder.
  def wait_until_blocked_by_queue(pid, blockers:, thread:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      observed = ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{Integer(pid)})::text")
      end
      return if parse_pg_int_array(observed).intersect?(blockers)

      unless thread.alive?
        thread.join
        raise "Archive notice worker #{pid} finished without blocking on #{blockers.inspect}"
      end
      raise "Archive notice worker #{pid} did not block on #{blockers.inspect}; blockers: #{observed}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      poll_pace
    end
  end

  # A raw insert: it takes the foreign key's shared lock without running the model's callbacks.
  def insert_rejected_review(application, admin, proof_type)
    now = Time.current
    ProofReview.insert!({
                          application_id: application.id, admin_id: admin.id, proof_type: ProofReview.proof_types.fetch(proof_type),
                          status: ProofReview.statuses.fetch(:rejected), rejection_reason: 'Unreadable',
                          decision_key: SecureRandom.uuid, decision_fingerprint: SecureRandom.hex(32),
                          reviewed_at: now, created_at: now, updated_at: now
                        })
  end
end
