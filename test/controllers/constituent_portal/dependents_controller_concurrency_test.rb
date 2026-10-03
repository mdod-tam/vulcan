# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  # DependentsController#create/#update and the merge service share User.lock_for_merge_integrity! locks.
  # The tests invoke actions directly with TestRequest/TestResponse and an injected current_user.
  # Routing and controller callbacks do not run.
  # See passwords_controller_concurrency_test.rb for the same setup.
  class DependentsControllerConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    # A merge between user and relationship creation could attach a dependent to a retired guardian.
    test 'merge commits first: dependent creation by the retired guardian fails closed with zero durable effects' do
      admin, canonical, retiring_guardian, review_case = build_guardian_creation_merge_fixtures
      dependent_email = "race-loser-#{SecureRandom.hex(4)}@example.com"
      initial_user_count = User.count
      initial_relationship_count = GuardianRelationship.count
      initial_portal_case_count = DuplicateReviewCase.where(source: :portal_dependent).count

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      merge_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          merge_result = run_merge(
            admin:,
            canonical:,
            duplicate: retiring_guardian,
            review_case:
          )
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      create_response = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        create_response = run_dependent_create(
          guardian: retiring_guardian,
          dependent_email:
        )
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert_equal :render, create_response[:action]
      assert_equal 422, create_response[:status]
      assert_equal initial_user_count, User.count
      assert_equal initial_relationship_count, GuardianRelationship.count
      assert_equal initial_portal_case_count, DuplicateReviewCase.where(source: :portal_dependent).count
      assert_not User.exists?(email: dependent_email)
      assert_not GuardianRelationship.exists?(guardian_id: retiring_guardian.id),
                 'the losing request must not attach a dependent to the retired guardian'
    ensure
      cleanup_duplicate_review_test_data!(
        admin,
        canonical,
        retiring_guardian,
        (User.find_by(email: dependent_email) if dependent_email)
      )
    end

    test 'dependent creation commits first: the merge waits, then transfers the new relationship' do
      admin, canonical, retiring_guardian, review_case = build_guardian_creation_merge_fixtures
      dependent_email = "race-winner-#{SecureRandom.hex(4)}@example.com"

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      create_response = nil
      guardian_lock_observed = false
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
            next unless payload[:sql].include?('"users"') && payload[:sql].include?('FOR UPDATE')

            bind_values = payload[:binds].map(&:value_for_database)
            guardian_lock_observed ||= bind_values == [retiring_guardian.id]
          end
          ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
            create_response = run_dependent_create(
              guardian: retiring_guardian,
              dependent_email:
            )
          end
          # The outer transaction delays commit after create returns, without a pause hook in production code.
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
        merge_result = run_merge(
          admin:,
          canonical:,
          duplicate: retiring_guardian,
          review_case:
        )
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      dependent = User.find_by!(email: dependent_email)
      assert guardian_lock_observed, 'create must lock the guardian before its first durable write'
      assert_equal :redirect, create_response[:action]
      assert merge_result.success?, "expected the merge to proceed normally once creation committed: #{merge_result&.message}"
      assert GuardianRelationship.exists?(guardian_id: canonical.id, dependent_id: dependent.id),
             'merge must transfer the relationship created by the winning request'
      assert_not GuardianRelationship.exists?(guardian_id: retiring_guardian.id, dependent_id: dependent.id)
    ensure
      cleanup_duplicate_review_test_data!(
        admin,
        canonical,
        retiring_guardian,
        (User.find_by(email: dependent_email) if dependent_email)
      )
    end

    test 'merge commits first: dependent creation snapshots the post-merge guardian phone' do
      guardian, guardian_duplicate, admin, existing_dependent, review_case = build_guardian_merge_fixtures
      dependent_email = "post-merge-contact-#{SecureRandom.hex(4)}@example.com"
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
      create_response = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        create_response = run_dependent_create(
          guardian:,
          dependent_email:,
          extra_dependent_params: { phone: '' }
        )
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      dependent = User.find_by!(email: dependent_email)
      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert_equal :redirect, create_response[:action]
      assert_equal User.normalize_phone(surviving_guardian_phone), User.normalize_phone(dependent.dependent_phone),
                   'the snapshot must come from the locked guardian after merge contact selection'
      assert_not_equal User.normalize_phone(discarded_guardian_phone), User.normalize_phone(dependent.dependent_phone),
                       'the pre-lock phone discarded by the merge must not become durable contact truth'
    ensure
      cleanup_duplicate_review_test_data!(
        guardian,
        guardian_duplicate,
        admin,
        existing_dependent,
        (User.find_by(email: dependent_email) if dependent_email)
      )
    end

    test 'review case database error rolls back before the create failure form renders' do
      candidate = create(
        :constituent,
        first_name: 'Created',
        last_name: 'Dependent',
        date_of_birth: Date.new(2010, 5, 15)
      )
      guardian = create(:constituent)
      dependent_email = "aborted-transaction-#{SecureRandom.hex(4)}@example.com"
      failing_case_service_class = Class.new(DuplicateReviewCases::CreateService) do
        private

        # Keep CreateService#call and its participant lock. Fail at the first case write.
        def create_open_case!
          ActiveRecord::Base.connection.execute('SELECT * FROM pr4d_intentionally_missing_relation')
        end
      end
      failing_case_service_factory = lambda do |**kwargs|
        failing_case_service_class.allocate.tap do |service|
          service.send(:initialize, **kwargs)
        end
      end
      Rails.logger.stubs(:warn)

      response = nil
      DuplicateReviewCases::CreateService.stub(:new, failing_case_service_factory) do
        assert_no_difference ['User.count', 'GuardianRelationship.count', 'DuplicateReviewCase.count',
                              'DuplicateReviewCaseCandidate.count', 'Event.count'] do
          response = run_dependent_create(
            guardian:,
            dependent_email:,
            query_before_failure_render: true
          )
        end
      end

      assert_equal :render, response[:action]
      assert_equal 422, response[:status]
      assert_not User.exists?(email: dependent_email)
    ensure
      cleanup_duplicate_review_test_data!(
        candidate,
        guardian,
        (User.find_by(email: dependent_email) if dependent_email)
      )
    end

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

    # A suspension while the request waits must revoke the guardian's authority to edit.
    # The dependent has a different rule: an unmerged inactive or suspended dependent remains editable.
    # See the guardian-edit cases in dependents_controller_test.rb.
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

    # User.editable_by_guardian proves the relationship exists only at the initial, unlocked lookup.
    # Removal while the request waits must revoke access. An unlocked recheck can read a row before concurrent deletion commits.
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

    # The edit must lock the relationship row FOR UPDATE until its write completes.
    # An unlocked exists? recheck would let this concurrent deletion proceed and fail the contention assertion.
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

    # The guardian survives this merge. The guardian strategy copies its phone into dependent_phone,
    # which User#effective_phone prefers.
    # A copy before the lock could preserve the discarded phone despite correct authorization under the lock.
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
        # A blank phone selects the guardian strategy on update.
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

    # Both requests pass detection before the guardian lock. The shared key must prevent a second dependent.
    test 'concurrent identical replays create exactly one dependent and one replay outcome' do
      guardian = create(:constituent)
      key = SecureRandom.hex(16)
      identity = unique_race_identity
      email = "replay-race-#{SecureRandom.hex(4)}@example.com"
      phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
      initial_users = User.count
      initial_relationships = GuardianRelationship.count

      results = run_creation_race(count: 2) do |at_barrier|
        run_dependent_create(
          guardian: guardian,
          dependent_email: email,
          portal_creation_key: key,
          extra_dependent_params: identity.merge(phone: phone),
          before_lock: at_barrier
        )
      end

      assert_equal 1, User.count - initial_users, 'exactly one dependent may survive the race'
      assert_equal 1, GuardianRelationship.count - initial_relationships
      assert_equal 1, GuardianRelationship.where(portal_creation_key: key).count
      assert(results.any? { |r| r[:notice].to_s.match?(/already added/i) },
             "one request must report the replay: #{results.inspect}")
    ensure
      cleanup_race_participants(guardian)
    end

    # Different keys exercise identity admission. One request succeeds, and support must resolve the refused request.
    test 'concurrent distinct requests for one identity create exactly one dependent' do
      guardian = create(:constituent)
      identity = unique_race_identity
      initial_users = User.count

      results = run_creation_race(count: 2) do |at_barrier|
        run_dependent_create(
          guardian: guardian,
          dependent_email: "admission-race-#{SecureRandom.hex(4)}@example.com",
          portal_creation_key: SecureRandom.hex(16),
          extra_dependent_params: identity.merge(phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"),
          before_lock: at_barrier
        )
      end

      assert_equal 1, User.count - initial_users, 'the identity rule must admit only one'
      # response_summary omits flash for renders, so this test compares status codes.
      # DependentsControllerTest asserts the refusal copy through a request.
      assert_equal 1, results.count { |r| r[:action] == :redirect },
                   "exactly one request may succeed: #{results.inspect}"
      assert_equal 1, results.count { |r| r[:action] == :render && r[:status] == 422 },
                   "the other must be refused: #{results.inspect}"
    ensure
      cleanup_race_participants(guardian)
    end

    private

    def build_guardian_creation_merge_fixtures
      admin = create(:admin)
      canonical = create(:constituent, email: "canonical-guardian-#{SecureRandom.hex(3)}@example.com", phone: nil)
      retiring_guardian = create(
        :constituent,
        email: "retiring-guardian-#{SecureRandom.hex(3)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: retiring_guardian,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(
        candidate_user: canonical,
        match_reason: 'name_dob',
        snapshot: {}
      )

      [admin, canonical, retiring_guardian, review_case]
    end

    # The guardian survives the merge. Its dependent is outside the merge pair,
    # but the merge still locks that dependent as a relationship neighbor.
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
      # Direct invocation bypasses #process, which sets action_name through @_action_name.
      # Without 'update', omitted fields select the guardian strategy instead of retaining stored contact.
      controller.instance_variable_set(:@_action_name, 'update')
      controller.instance_variable_set(:@current_user, fresh_guardian)
      controller.instance_variable_set(:@dependent, fresh_dependent)
      controller.params = ActionController::Parameters.new(
        dependent: { first_name: 'Updated', last_name: fresh_dependent.last_name }.merge(extra_dependent_params)
      )

      controller.send(:update)

      response_summary(controller)
    end

    def run_dependent_create(guardian:, dependent_email:, extra_dependent_params: {},
                             query_before_failure_render: false, portal_creation_key: nil,
                             before_lock: nil)
      fresh_guardian = User.find(guardian.id)

      controller = ConstituentPortal::DependentsController.new
      controller.set_request!(ActionDispatch::TestRequest.create)
      controller.set_response!(ActionDispatch::TestResponse.new)
      controller.instance_variable_set(:@_action_name, 'create')
      controller.instance_variable_set(:@current_user, fresh_guardian)
      controller.params = ActionController::Parameters.new(
        dependent: {
          first_name: 'Created',
          last_name: 'Dependent',
          date_of_birth: '05/15/2010',
          email: dependent_email,
          phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
          hearing_disability: true
        }.merge(extra_dependent_params),
        guardian_relationship: { relationship_type: 'Parent' },
        portal_creation_key: portal_creation_key
      )
      # Pause after duplicate detection so both requests reach the guardian lock together.
      if before_lock
        controller.define_singleton_method(:create_portal_dependent_atomically) do |*args|
          before_lock.call
          super(*args)
        end
      end
      if query_before_failure_render
        controller.define_singleton_method(:handle_creation_failure) do |errors|
          User.count
          super(errors)
        end
      end

      controller.send(:create)

      response_summary(controller)
    end

    # These requests lock different guardians. Key uniqueness must include the guardian ID.
    # A global unique index could raise RecordNotUnique when an unrelated account uses the same key.
    test 'concurrent identical keys from different guardians are independently spendable' do
      guardian_a = create(:constituent)
      guardian_b = create(:constituent)
      key = SecureRandom.hex(16)
      identity_a = unique_race_identity
      identity_b = unique_race_identity
      initial_users = User.count

      # Queue provides safe assignment to concurrent racers.
      assignments = Queue.new
      assignments << [guardian_a, identity_a] << [guardian_b, identity_b]
      results = run_creation_race(count: 2) do |at_barrier|
        guardian, identity = assignments.pop
        run_dependent_create(
          guardian: guardian,
          dependent_email: "cross-guardian-#{SecureRandom.hex(4)}@example.com",
          portal_creation_key: key,
          extra_dependent_params: identity.merge(phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"),
          before_lock: at_barrier
        )
      end

      assert_equal 2, User.count - initial_users, 'both guardians must be able to spend the same raw key'
      assert_equal 2, results.count { |r| r[:action] == :redirect }, results.inspect
      assert_equal 1, GuardianRelationship.where(guardian_id: guardian_a.id, portal_creation_key: key).count
      assert_equal 1, GuardianRelationship.where(guardian_id: guardian_b.id, portal_creation_key: key).count
    ensure
      cleanup_race_participants(guardian_a)
      cleanup_race_participants(guardian_b)
    end

    # Nontransactional tests can expose leftover rows to later tests.
    # The default 'Created Dependent' identity could add a soft-match candidate and break the assertion for exact lock binds.
    # Each race uses a separate identity.
    def unique_race_identity
      token = SecureRandom.hex(4)
      { first_name: "Racer#{token}", last_name: "Case#{token}", date_of_birth: '03/09/2013' }
    end

    def cleanup_race_participants(guardian)
      return if guardian.blank?

      dependent_ids = GuardianRelationship.where(guardian_id: guardian.id).pluck(:dependent_id)
      cleanup_duplicate_review_test_data!([guardian, *User.where(id: dependent_ids)])
    end

    # The barrier releases racers after all pass detection, so they contend at the guardian lock.
    def run_creation_race(count:)
      arrived = Queue.new
      release = Queue.new
      at_barrier = lambda do
        arrived << :ready
        release.pop
      end

      threads = Array.new(count) { on_own_connection { yield(at_barrier) } }
      count.times { arrived.pop }
      count.times { release << :go }
      threads.map(&:value)
    end

    def response_summary(controller)
      if controller.response.redirect?
        {
          action: :redirect,
          status: controller.response.status,
          notice: controller.send(:flash)[:notice],
          alert: controller.send(:flash)[:alert]
        }
      else
        { action: :render, status: controller.response.status }
      end
    end
  end
end
