# frozen_string_literal: true

require 'test_helper'

module Applications
  # Focused both-orderings evidence for RequestProofResubmission's use of the shared
  # SecureRequestIssuanceIntegrity owner.
  class RequestProofResubmissionConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'merge commits first: the subsequent proof-resubmission request correctly targets the new owner' do
      admin, canonical, duplicate, review_case = build_fixtures
      application = create(:application, user: duplicate)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      merge_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          merge_result = run_merge(admin:, canonical:, duplicate:, review_case:)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      issuance_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        issuance_result = run_proof_resubmission_request(admin:, application:)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert issuance_result.success?, "expected the issuance to succeed against the new owner: #{issuance_result&.message}"
      form = issuance_result.data[:secure_request_forms].first
      assert_equal canonical.id, form.recipient_id,
                   'the request must target the current (post-merge) owner, never the stale pre-merge recipient'
      assert_single_issuance_side_effects(application)
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'issuance commits first: the merge then fails closed on the freshly-active proof request' do
      admin, canonical, duplicate, review_case = build_fixtures
      application = create(:application, user: duplicate)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      issuance_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          issuance_result = run_proof_resubmission_request(admin:, application:)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      merge_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        merge_result = run_merge(admin:, canonical:, duplicate:, review_case:)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert issuance_result.success?, "expected the issuance (holder) to succeed: #{issuance_result&.message}"
      form = issuance_result.data[:secure_request_forms].first
      assert_equal duplicate.id, form.recipient_id, 'the committed issuance must have targeted the still-live duplicate'
      assert merge_result.failure?, 'expected the merge to fail closed against the freshly-active secure request form'
      assert_match(/active secure request form/i, merge_result.message)
      assert_not duplicate.reload.merged?, 'zero side effects: the duplicate must remain unmerged'
      assert_single_issuance_side_effects(application)
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    private

    def assert_single_issuance_side_effects(application)
      assert_equal 1, SecureRequestForm.where(application:, kind: :income_proof_resubmission).count
      notification = Notification.find_by!(notifiable: application, action: 'proof_resubmission_requested')
      assert_equal 1, Notification.where(notifiable: application, action: 'proof_resubmission_requested').count
      assert_predicate notification, :audited?
    end

    def build_fixtures
      admin = create(:admin)
      canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
      duplicate = nil
      begin
        Current.paper_context = true
        duplicate = create(:constituent, email: nil, phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
                                         communication_preference: :letter)
      ensure
        Current.reset
      end

      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: duplicate,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['exact_phone'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(candidate_user: canonical, match_reason: 'exact_phone', snapshot: {})

      [admin, canonical, duplicate, review_case]
    end

    def run_merge(admin:, canonical:, duplicate:, review_case:)
      Users::DuplicateMergeService.new(
        actor: User.find(admin.id),
        duplicate_review_case: DuplicateReviewCase.find(review_case.id),
        canonical_user: User.find(canonical.id),
        duplicate_user: User.find(duplicate.id),
        same_person_confirmed: true,
        rationale: 'confirmed same person via support call',
        reason_codes: %w[exact_phone],
        contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' },
        delivery_choice: 'canonical'
      ).call
    end

    def run_proof_resubmission_request(admin:, application:)
      RequestProofResubmission.new(
        application: Application.find(application.id),
        actor: User.find(admin.id),
        proof_type: :income
      ).call
    end
  end
end
