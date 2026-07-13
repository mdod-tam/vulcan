# frozen_string_literal: true

require 'test_helper'

class ConcurrentMergeApplicationWritersTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test 'autosave blocks on and rejects a user retired by a concurrent merge' do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    duplicate = create(:constituent)
    canonical = create(:constituent)
    stale_duplicate = User.find(duplicate.id)
    lock_held = Queue.new
    release_merge = Queue.new
    writer_result = nil
    merge_error = nil
    writer_error = nil

    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          locked = User.lock.find(duplicate.id)
          lock_held << true
          raise 'timed out waiting to release merge' unless release_merge.pop(timeout: 5)

          locked.update_columns(
            email: nil,
            phone: nil,
            status: User.statuses[:inactive],
            merged_into_user_id: canonical.id,
            merged_at: Time.current,
            updated_at: Time.current
          )
        end
      end
    rescue StandardError => e
      merge_error = e
    end

    assert lock_held.pop(timeout: 5), 'merge did not acquire the duplicate user lock'
    writer_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_result = Applications::AutosaveService.new(
          current_user: stale_duplicate,
          params: { field_name: 'application[household_size]', field_value: '3' }
        ).call
      end
    rescue StandardError => e
      writer_error = e
    end

    sleep 0.2
    assert writer_thread.alive?, 'autosave should wait for the merge user-row lock'
    release_merge << true
    assert merge_thread.join(5), <<~MESSAGE
      merge thread did not finish
      backtrace: #{merge_thread.backtrace&.join("\n")}
    MESSAGE
    assert writer_thread.join(5), 'autosave thread did not finish'

    assert_nil merge_error, merge_error&.full_message
    assert_nil writer_error, writer_error&.full_message
    assert_not writer_result[:success]
    assert_match(/no longer active/i, writer_result.dig(:errors, :base).to_sentence)
    assert_not Application.exists?(user_id: duplicate.id)
  ensure
    release_merge << true if defined?(release_merge) && release_merge.empty?
    merge_thread&.join(5)
    writer_thread&.join(5)
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :transaction
  end

  test 'merge waits for writer-first autosave and transfers the committed draft' do
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean

    actor = create(:admin)
    duplicate = create(:constituent, phone: nil)
    canonical = create(:constituent, phone: nil)
    review_case = merge_case(subject: duplicate, candidate: canonical)
    writer_saved = Queue.new
    release_writer = Queue.new
    merge_started = Queue.new
    writer_result = nil
    merge_result = nil
    writer_error = nil
    merge_error = nil

    writer_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          locked_duplicate = User.lock.find(duplicate.id)
          writer_result = Applications::AutosaveService.new(
            current_user: locked_duplicate,
            params: { field_name: 'application[household_size]', field_value: '3' }
          ).call
          writer_saved << true
          raise 'timed out waiting to release writer' unless release_writer.pop(timeout: 5)
        end
      end
    rescue StandardError => e
      writer_error = e
    end

    assert writer_saved.pop(timeout: 5), 'autosave did not commit its draft inside the writer transaction'
    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        merge_started << true
        merge_result = merge_service(
          actor: actor,
          review_case: review_case,
          canonical: canonical,
          duplicate: duplicate
        ).call
      end
    rescue StandardError => e
      merge_error = e
    end

    assert merge_started.pop(timeout: 5), 'merge thread did not start'
    sleep 0.2
    assert merge_thread.alive?, 'merge should wait for the writer-held user-row lock'
    release_writer << true
    assert writer_thread.join(5), 'autosave thread did not finish'
    assert merge_thread.join(5), <<~MESSAGE
      merge thread did not finish
      backtrace: #{merge_thread.backtrace&.join("\n")}
    MESSAGE

    assert_nil writer_error, writer_error&.full_message
    assert_nil merge_error, merge_error&.full_message
    assert writer_result[:success], writer_result.inspect
    assert merge_result.success?, merge_result.message
    assert_equal canonical.id, Application.find(writer_result.fetch(:application_id)).user_id
    assert duplicate.reload.merged?
  ensure
    release_writer << true if defined?(release_writer) && release_writer.empty?
    writer_thread&.join(5)
    merge_thread&.join(5)
    DatabaseCleaner.clean
    DatabaseCleaner.strategy = :transaction
  end

  private

  def merge_case(subject:, candidate:)
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

  def merge_service(actor:, review_case:, canonical:, duplicate:)
    Users::DuplicateMergeService.new(
      actor: actor,
      duplicate_review_case: review_case,
      canonical_user: canonical,
      duplicate_user: duplicate,
      same_person_confirmed: true,
      rationale: 'Confirmed same person for concurrency regression.',
      reason_codes: ['name_dob'],
      contact_choices: { email: 'canonical', phone: 'canonical', address: 'canonical' },
      delivery_choice: 'canonical'
    )
  end
end
