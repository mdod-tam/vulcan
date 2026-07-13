# frozen_string_literal: true

require 'test_helper'

class ConcurrentMergeCandidateResolutionTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test 'resolution-first terminal evidence is not rewritten by a waiting merge' do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean
    records = build_records
    candidate = records.fetch(:candidate_case).duplicate_review_case_candidates.sole
    original_candidate = candidate.attributes.slice('candidate_user_id', 'match_reason', 'snapshot')
    original_key = records.fetch(:candidate_case).deduplication_key
    resolution_written = Queue.new
    release_resolution = Queue.new
    resolution_result = nil
    merge_result = nil
    resolution_error = nil
    merge_error = nil

    resolution_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          resolution_result = resolution_service(records).call
          resolution_written << true
          raise 'timed out waiting to release resolution' unless release_resolution.pop(timeout: 5)
        end
      end
    rescue StandardError => e
      resolution_error = e
    end

    assert resolution_written.pop(timeout: 5), 'resolution did not write its terminal decision'
    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        merge_result = merge_service(records).call
      end
    rescue StandardError => e
      merge_error = e
    end

    sleep 0.2
    assert merge_thread.alive?, 'merge should wait for the candidate case row lock'
    release_resolution << true
    assert resolution_thread.join(5), 'resolution thread did not finish'
    assert merge_thread.join(5), 'merge thread did not finish'

    assert_nil resolution_error, resolution_error&.full_message
    assert_nil merge_error, merge_error&.full_message
    assert resolution_result.success?, resolution_result.message
    assert merge_result.success?, merge_result.message
    candidate.reload
    assert_equal original_candidate, candidate.attributes.slice('candidate_user_id', 'match_reason', 'snapshot')
    assert_equal original_key, records.fetch(:candidate_case).reload.deduplication_key
    assert records.fetch(:candidate_case).resolved_keep_separate?
  ensure
    release_resolution << true if defined?(release_resolution) && release_resolution.empty?
    resolution_thread&.join(5)
    merge_thread&.join(5)
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :transaction
  end

  test 'merge-first repoint commits before a waiting terminal resolution' do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean
    records = build_records
    merge_written = Queue.new
    release_merge = Queue.new
    merge_result = nil
    resolution_result = nil
    merge_error = nil
    resolution_error = nil

    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          merge_result = merge_service(records).call
          merge_written << true
          raise 'timed out waiting to release merge' unless release_merge.pop(timeout: 5)
        end
      end
    rescue StandardError => e
      merge_error = e
    end

    assert merge_written.pop(timeout: 5), 'merge did not write its candidate-case changes'
    resolution_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        resolution_result = resolution_service(records).call
      end
    rescue StandardError => e
      resolution_error = e
    end

    sleep 0.2
    assert resolution_thread.alive?, 'resolution should wait for the merge-held candidate case lock'
    release_merge << true
    assert merge_thread.join(5), 'merge thread did not finish'
    assert resolution_thread.join(5), 'resolution thread did not finish'

    assert_nil merge_error, merge_error&.full_message
    assert_nil resolution_error, resolution_error&.full_message
    assert merge_result.success?, merge_result.message
    assert resolution_result.success?, resolution_result.message
    candidate_case = records.fetch(:candidate_case).reload
    assert candidate_case.resolved_keep_separate?
    assert_equal [records.fetch(:canonical).id], candidate_case.duplicate_review_case_candidates.pluck(:candidate_user_id)
    expected_key = DuplicateReviewCases::DeduplicationKey.call(
      source: candidate_case.source,
      subject_user_id: candidate_case.subject_user_id,
      reason_codes: ['name_dob'],
      candidate_user_ids: [records.fetch(:canonical).id]
    )
    assert_equal expected_key, candidate_case.deduplication_key
  ensure
    release_merge << true if defined?(release_merge) && release_merge.empty?
    merge_thread&.join(5)
    resolution_thread&.join(5)
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :transaction
  end

  private

  def build_records
    actor = create(:admin)
    canonical = create(:constituent, phone: nil)
    duplicate = create(:constituent, phone: nil)
    subject = create(:constituent)
    merge_case = open_case(subject: duplicate, candidate: canonical)
    candidate_result = DuplicateReviewCases::CreateService.new(
      source: :support_claim,
      subject_user: subject,
      actor: actor,
      reason_codes: ['name_dob'],
      candidates: [
        DuplicateReviewCases::CreateService::CandidateInput.new(
          duplicate,
          'name_dob',
          { real_email: duplicate.real_email? }
        )
      ]
    ).call
    assert candidate_result.success?, candidate_result.message

    {
      actor: actor,
      canonical: canonical,
      duplicate: duplicate,
      subject: subject,
      merge_case: merge_case,
      candidate_case: candidate_result.data.fetch(:duplicate_review_case)
    }
  end

  def open_case(subject:, candidate:)
    review_case = DuplicateReviewCase.create!(
      source: :support_claim,
      subject_user: subject,
      deduplication_key: SecureRandom.hex(16),
      metadata: { 'reason_codes' => ['name_dob'] },
      opened_at: Time.current,
      status: :open
    )
    review_case.duplicate_review_case_candidates.create!(candidate_user: candidate, match_reason: 'name_dob', snapshot: {})
    review_case
  end

  def merge_service(records)
    Users::DuplicateMergeService.new(
      actor: User.find(records.fetch(:actor).id),
      duplicate_review_case: DuplicateReviewCase.find(records.fetch(:merge_case).id),
      canonical_user: User.find(records.fetch(:canonical).id),
      duplicate_user: User.find(records.fetch(:duplicate).id),
      same_person_confirmed: true,
      rationale: 'Confirmed same person for candidate concurrency regression.',
      reason_codes: ['name_dob'],
      contact_choices: { email: 'canonical', phone: 'canonical', address: 'canonical' },
      delivery_choice: 'canonical'
    )
  end

  def resolution_service(records)
    DuplicateReviewCases::ResolutionService.new(
      duplicate_review_case: DuplicateReviewCase.find(records.fetch(:candidate_case).id),
      actor: User.find(records.fetch(:actor).id),
      outcome: 'keep_separate',
      rationale: 'Terminal evidence must remain stable.',
      reason_codes: ['name_dob']
    )
  end
end
