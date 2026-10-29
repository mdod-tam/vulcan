# frozen_string_literal: true

require 'test_helper'

# Inserting a review takes a shared lock on its application row for the foreign key. Counting a rejection
# needs the exclusive lock. Two rejections that each hold the shared lock wait on each other for the
# exclusive one, so record! locks the application before it inserts the review.
class ProofReviewConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'a rejection takes the application lock before inserting its review, so concurrent rejections cannot deadlock' do
    admin = create(:admin)
    application = create(:application)

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
      review = ProofReview.for_decision(Application.find(application.id), proof_type: :income, status: :rejected)
      # The post-commit notices are not under test.
      review.define_singleton_method(:handle_post_review_actions) { nil }
      review.record!(admin: admin, rejection_reason: 'Unreadable')
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

  private

  # A raw insert: it takes the foreign key's shared lock without running the model's callbacks.
  def insert_rejected_review(application, admin, proof_type)
    now = Time.current
    ProofReview.insert!({
                          application_id: application.id, admin_id: admin.id, proof_type: ProofReview.proof_types.fetch(proof_type),
                          status: ProofReview.statuses.fetch(:rejected), rejection_reason: 'Unreadable',
                          reviewed_at: now, created_at: now, updated_at: now
                        })
  end
end
