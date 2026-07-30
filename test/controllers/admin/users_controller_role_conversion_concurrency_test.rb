# frozen_string_literal: true

require 'test_helper'

module Admin
  # Focused concurrency evidence for the STI role-conversion boundary (plan section 4):
  # Admin::UsersController#handle_role_change and the merge service must serialize through
  # User.lock_for_merge_integrity! on the target user, closing the previous gap where
  # converted_user.save(validate: false) could silently rewrite a retired duplicate's `type`
  # column (validate: false bypasses the merged_record_immutable validation entirely).
  #
  # Exercises the real, private controller method directly (via a minimal
  # ActionDispatch::TestRequest/TestResponse pair, using set_request!/set_response! rather
  # than the public request=/response= setters -- see passwords_controller_concurrency_test.rb
  # for why: Metal#response= deliberately forces performed? to true, which would make the
  # first real `render json:` call raise DoubleRenderError). Both sides of every race are real
  # production code.
  class UsersControllerRoleConversionConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'merge commits first: role conversion on the newly-merged duplicate then refuses with zero writes' do
      admin, canonical, duplicate, review_case = build_fixtures

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
      conversion_response = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        conversion_response = run_role_conversion(duplicate)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert_equal false, conversion_response[:success]
      assert_match(/no longer an eligible active record/i, conversion_response[:message])
      assert_equal 'Users::Constituent', duplicate.reload.type,
                   "zero side effects: the merged duplicate's type must be untouched by the losing conversion attempt"
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'role conversion commits first: the merge then correctly fails closed on the no-longer-constituent duplicate' do
      admin, canonical, duplicate, review_case = build_fixtures

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      conversion_response = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          conversion_response = run_role_conversion(duplicate)
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

      assert_equal true, conversion_response[:success], "expected the conversion (holder) to succeed: #{conversion_response.inspect}"
      # User.find (not duplicate.reload): the in-memory `duplicate` is still typed
      # Users::Constituent, and reloading through that STI subclass would add an implicit
      # `type = 'Users::Constituent'` predicate that no longer matches the row now that the
      # holder converted it -- the same class-vs-base-class gotcha user_merge_integrity.rb's
      # currently_merged_in_database? had to guard against.
      assert_equal 'Users::Administrator', User.find(duplicate.id).type
      assert merge_result.failure?, 'expected the merge to fail closed once the duplicate was no longer a constituent'
      assert_match(/only constituent records/i, merge_result.message)
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    private

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

    def run_role_conversion(user)
      controller = Admin::UsersController.new
      controller.set_request!(ActionDispatch::TestRequest.create)
      controller.set_response!(ActionDispatch::TestResponse.new)
      controller.params = ActionController::Parameters.new

      controller.send(:handle_role_change, User.find(user.id), 'Users::Administrator')

      JSON.parse(controller.response.body, symbolize_names: true)
    end
  end
end
