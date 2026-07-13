# frozen_string_literal: true

require 'test_helper'

# Proves duplicate-case creation shares the merge user-row lock rather than relying
# only on a stale-object reload. The merge holds the subject lock until the writer is
# blocked, retires the subject, and then lets creation revalidate the committed state.
class ConcurrentMergeCaseCreationTest < ActionDispatch::IntegrationTest
  test 'case creation blocks on and rejects a subject retired by a concurrent merge' do
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    subject = create(:constituent)
    candidate = create(:constituent)
    canonical = create(:constituent)
    actor = create(:admin)

    lock_held = Queue.new
    release_merge = Queue.new
    merge_done = Queue.new

    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          locked = User.lock.find(subject.id)
          lock_held << true
          release_merge.pop
          locked.update!(status: :inactive, merged_into_user: canonical, merged_at: Time.current)
        end
      end
    ensure
      merge_done << true
    end

    lock_held.pop

    writer_result = nil
    writer_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_result = DuplicateReviewCases::CreateService.new(
          source: :registration_soft_match,
          subject_user: User.find(subject.id),
          actor: actor,
          reason_codes: ['name_dob'],
          candidates: [
            DuplicateReviewCases::CreateService::CandidateInput.new(candidate, 'name_dob', {})
          ]
        ).call
      end
    end

    sleep 0.2
    assert writer_thread.alive?, 'case creation should be blocked on the subject row lock'

    release_merge << true
    merge_done.pop
    writer_thread.join(5)

    assert writer_result.failure?
    assert_match(/no longer active/i, writer_result.message)
    assert_not subject.reload.needs_duplicate_review
    assert_not DuplicateReviewCase.pending_review.for_subject(subject).exists?
  ensure
    release_merge << true if defined?(release_merge) && release_merge.empty?
    merge_thread&.join(5)
    writer_thread&.join(5)
    DatabaseCleaner.strategy = :transaction
  end
end
