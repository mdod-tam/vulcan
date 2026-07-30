# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  # Focused concurrency evidence for the primary contact/profile edit boundary (plan section
  # 4, row 3), guardian-managed-dependent variant:
  # ConstituentPortal::DependentsController#update and the merge service must serialize
  # through User.lock_for_merge_integrity! on the dependent -- the merge target here, since
  # the *dependent* (not the guardian) is the one being retired.
  #
  # Exercises the real, private controller method directly (via a minimal
  # ActionDispatch::TestRequest/TestResponse pair, using set_request!/set_response! -- see
  # passwords_controller_concurrency_test.rb for why -- and injecting current_user directly)
  # rather than through routing. Both sides of every race are real production code.
  class DependentsControllerConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'merge commits first: dependent edit for the newly-merged duplicate dependent fails closed with zero writes' do
      guardian, admin, canonical, duplicate, review_case = build_fixtures
      original_first_name = duplicate.first_name

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
      update_response = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        update_response = run_dependent_edit(guardian:, dependent: duplicate)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert_equal :redirect, update_response[:action]
      assert_match(/no longer available/i, update_response[:alert])
      assert_equal original_first_name, duplicate.reload.first_name,
                   'zero side effects: the merged duplicate dependent must be untouched by the losing edit'
    ensure
      cleanup_duplicate_review_test_data!(guardian, admin, canonical, duplicate)
    end

    test 'dependent edit commits first: the merge then proceeds normally' do
      guardian, admin, canonical, duplicate, review_case = build_fixtures

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      update_response = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          update_response = run_dependent_edit(guardian:, dependent: duplicate)
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

      assert_equal :redirect, update_response[:action]
      assert_equal 'Updated', duplicate.reload.first_name, 'the committed edit must have taken effect'
      assert merge_result.success?, "expected the merge to proceed normally once the dependent edit committed: #{merge_result&.message}"
    ensure
      cleanup_duplicate_review_test_data!(guardian, admin, canonical, duplicate)
    end

    # Retirement is not the only way the guardian can lose authority while its request waits.
    # The guardian is the authenticated actor, so a suspension landing inside the lock window
    # must end the edit too -- before the fix, #update rechecked only merged? and would honor an
    # edit from an actor that could no longer sign in. (The dependent is deliberately held to a
    # different standard: see the "guardian can edit an unmerged inactive/suspended dependent"
    # cases in dependents_controller_test.rb.)
    test 'guardian suspension commits first: the dependent edit then fails closed with zero writes' do
      guardian, admin, canonical, duplicate, _review_case = build_fixtures
      original_first_name = duplicate.first_name

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          locked_guardian = User.lock_for_merge_integrity!(guardian).fetch(guardian.id)
          locked_guardian.update!(status: :suspended)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      update_response = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        update_response = run_dependent_edit(guardian:, dependent: duplicate)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert_equal :redirect, update_response[:action]
      assert_match(/no longer available/i, update_response[:alert])
      assert_equal original_first_name, duplicate.reload.first_name,
                   'zero side effects: a suspended guardian must not land an edit that was authorized before the suspension'
    ensure
      cleanup_duplicate_review_test_data!(guardian, admin, canonical, duplicate)
    end

    # set_dependent's User.editable_by_guardian scope proves the relationship existed at lookup
    # time, unlocked. If it is removed while the request waits for the user lock, the edit is no
    # longer authorized by anything -- the previous unlocked exists? recheck could still observe
    # the row a concurrent removal was about to delete.
    test 'relationship removal commits first: the dependent edit then fails closed with zero writes' do
      guardian, admin, canonical, duplicate, _review_case = build_fixtures
      original_first_name = duplicate.first_name

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          User.lock_for_merge_integrity!(duplicate, guardian)
          GuardianRelationship.where(guardian_id: guardian.id, dependent_id: duplicate.id).delete_all
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      update_response = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        update_response = run_dependent_edit(guardian:, dependent: duplicate)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert_equal :redirect, update_response[:action]
      assert_match(/no longer available/i, update_response[:alert])
      assert_equal original_first_name, duplicate.reload.first_name,
                   'zero side effects: an edit whose authorizing relationship was removed must not land'
    ensure
      cleanup_duplicate_review_test_data!(guardian, admin, canonical, duplicate)
    end

    # Proves the mechanism rather than an outcome: the edit holds the *relationship* row itself
    # FOR UPDATE, not merely the two user rows. A concurrent removal physically blocks on it, so
    # the authorizing row cannot be deleted between the recheck and the write. If the recheck
    # were an unlocked exists? again, this delete would not block and the test would fail.
    test "a relationship removal physically blocks on the dependent edit's own row lock" do
      guardian, admin, canonical, duplicate, _review_case = build_fixtures

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      update_response = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          update_response = run_dependent_edit(guardian:, dependent: duplicate)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        GuardianRelationship.where(guardian_id: guardian.id, dependent_id: duplicate.id).delete_all
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert_equal :redirect, update_response[:action]
      assert_equal 'Updated', duplicate.reload.first_name, 'the committed edit must have taken effect'
      assert_not GuardianRelationship.exists?(guardian_id: guardian.id, dependent_id: duplicate.id),
                 'the removal must proceed once the edit released its lock'
    ensure
      cleanup_duplicate_review_test_data!(guardian, admin, canonical, duplicate)
    end

    # The cases above make the *dependent* the merge target. This one makes the *guardian* the
    # canonical survivor, which is where stale contact derivation shows up: a guardian contact
    # strategy snapshots the guardian's own phone into the dependent's stored dependent_phone, and
    # User#effective_phone prefers it. Deriving that snapshot before the lock would make the
    # discarded pre-merge number the dependent's durable contact truth even though the edit
    # correctly reauthorized under the lock.
    test 'merge commits first: the dependent edit snapshots the post-merge guardian phone' do
      guardian, guardian_duplicate, admin, dependent, review_case = build_guardian_merge_fixtures
      discarded_guardian_phone = guardian.phone
      surviving_guardian_phone = guardian_duplicate.phone

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      merge_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          merge_result = run_merge(admin:, canonical: guardian, duplicate: guardian_duplicate, review_case:)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      update_response = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        # Submitting a blank phone selects the guardian phone strategy for this update.
        update_response = run_dependent_edit(guardian:, dependent:, extra_dependent_params: { phone: '' })
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert_equal :redirect, update_response[:action]

      dependent.reload
      assert_equal User.normalize_phone(surviving_guardian_phone), User.normalize_phone(dependent.dependent_phone),
                   'the snapshot must come from the locked guardian, i.e. the phone the merge left in place'
      assert_not_equal User.normalize_phone(discarded_guardian_phone), User.normalize_phone(dependent.dependent_phone),
                       'the pre-lock guardian phone the merge discarded must never become dependent contact truth'
      assert_equal User.normalize_phone(surviving_guardian_phone), User.normalize_phone(dependent.effective_phone),
                   'effective_phone prefers dependent_phone, so a stale snapshot would misroute notifications'
    ensure
      cleanup_duplicate_review_test_data!(guardian, guardian_duplicate, admin, dependent)
    end

    test 'dependent edit commits first: the guardian merge then proceeds normally' do
      guardian, guardian_duplicate, admin, dependent, review_case = build_guardian_merge_fixtures
      pre_merge_guardian_phone = guardian.phone

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      update_response = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          update_response = run_dependent_edit(guardian:, dependent:, extra_dependent_params: { phone: '' })
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
        merge_result = run_merge(admin:, canonical: guardian, duplicate: guardian_duplicate, review_case:)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert_equal :redirect, update_response[:action]
      assert_equal User.normalize_phone(pre_merge_guardian_phone), User.normalize_phone(dependent.reload.dependent_phone),
                   'the edit committed first, so it correctly snapshotted the guardian phone of that moment'
      assert merge_result.success?, "expected the merge to proceed normally once the edit committed: #{merge_result&.message}"
    ensure
      cleanup_duplicate_review_test_data!(guardian, guardian_duplicate, admin, dependent)
    end

    private

    # Guardian-as-canonical-survivor pair, plus a dependent of that guardian. The dependent is
    # not a merge participant, so the two transactions collide only on the guardian's user row.
    def build_guardian_merge_fixtures
      admin = create(:admin)
      guardian = create(:constituent, email: "guardian-#{SecureRandom.hex(3)}@example.com",
                                      phone: '555-867-5309', phone_type: 'voice')
      guardian_duplicate = nil
      dependent = nil
      begin
        Current.paper_context = true
        guardian_duplicate = create(:constituent, email: nil, phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
                                                  communication_preference: :letter)
        dependent = create(:constituent, email: "dependent-#{SecureRandom.hex(3)}@example.com",
                                         phone: "555-#{rand(100..999)}-#{rand(1000..9999)}")
      ensure
        Current.reset
      end
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: guardian_duplicate,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(candidate_user: guardian, match_reason: 'name_dob', snapshot: {})

      [guardian, guardian_duplicate, admin, dependent, review_case]
    end

    def build_fixtures
      guardian = create(:constituent, email: "guardian-#{SecureRandom.hex(3)}@example.com")
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
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: duplicate, relationship_type: 'Parent')

      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: duplicate,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['exact_phone'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(candidate_user: canonical, match_reason: 'exact_phone', snapshot: {})

      [guardian, admin, canonical, duplicate, review_case]
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

    def run_dependent_edit(guardian:, dependent:, extra_dependent_params: {})
      fresh_guardian = User.find(guardian.id)
      fresh_dependent = User.find(dependent.id)

      controller = ConstituentPortal::DependentsController.new
      controller.set_request!(ActionDispatch::TestRequest.create)
      controller.set_response!(ActionDispatch::TestResponse.new)
      # action_name (Rails' attr_internal, backed by @_action_name) is normally set by
      # #process during real dispatch, which this direct-invocation technique never runs.
      # Without it, #update's own contact_strategy_for reads action_name == 'update' as
      # false and takes the "field omitted from params" branch instead of the "not submitted
      # on an update" branch, wrongly triggering a guardian contact-strategy override.
      controller.instance_variable_set(:@_action_name, 'update')
      controller.instance_variable_set(:@current_user, fresh_guardian)
      controller.instance_variable_set(:@dependent, fresh_dependent)
      controller.params = ActionController::Parameters.new(
        dependent: { first_name: 'Updated', last_name: fresh_dependent.last_name }.merge(extra_dependent_params)
      )

      controller.send(:update)

      response_summary(controller)
    end

    def response_summary(controller)
      if controller.response.redirect?
        { action: :redirect, notice: controller.send(:flash)[:notice], alert: controller.send(:flash)[:alert] }
      else
        { action: :render }
      end
    end
  end
end
