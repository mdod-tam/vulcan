# frozen_string_literal: true

require 'test_helper'

module Applications
  # Focused concurrency evidence for the autosave boundary (plan section 4): autosave's
  # user-field writer and the merge service must serialize through
  # User.lock_for_merge_integrity! on the target user, exactly like the sections 1-3 shared
  # primitive already requires of merge itself. Both sides of every race are the real
  # production services -- including the "holder" side, which is the *winning* transaction,
  # not a copy of its effects (see create_service_concurrency_test.rb's header comment for
  # why wrapping a real service call in an outer `transaction do ... end` works).
  class AutosaveServiceConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'merge commits first: autosave on the newly-merged duplicate then fails closed with zero writes' do
      admin, canonical, duplicate, review_case = build_fixtures
      draft = create(:application, :draft, user: duplicate)

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
      autosave_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        autosave_result = run_autosave(user: duplicate, application_id: draft.id)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert_not autosave_result[:success], 'expected autosave to fail closed once the target user was merged'
      assert_includes autosave_result[:errors][:base], 'This record is no longer an eligible active record.'
      assert_not duplicate.reload.vision_disability, 'the merged duplicate must show zero side effects from the losing autosave'
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'autosave commits first: the merge then proceeds normally, observing the autosaved value' do
      admin, canonical, duplicate, review_case = build_fixtures
      draft = create(:application, :draft, user: duplicate)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      autosave_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          autosave_result = run_autosave(user: duplicate, application_id: draft.id)
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

      assert autosave_result[:success], "expected autosave (holder) to succeed: #{autosave_result.inspect}"
      assert merge_result.success?, "expected the merge to proceed normally once autosave committed: #{merge_result&.message}"
      assert duplicate.reload.vision_disability, "the autosaved value must survive on the retired duplicate's own row"
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'merge commits first: application-field autosave on the newly-merged duplicate then fails closed with zero writes' do
      admin, canonical, duplicate, review_case = build_fixtures
      draft = create(:application, :draft, user: duplicate, household_size: 1)

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
      autosave_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        autosave_result = run_autosave_application_field(user: duplicate, application_id: draft.id)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert_not autosave_result[:success], 'expected autosave to fail closed once the target participant was merged'
      assert_includes autosave_result[:errors][:base], 'This record is no longer an eligible active record.'
      draft.reload
      assert_equal 1, draft.household_size, 'zero side effects: the application field must be untouched by the losing autosave'
      assert_nil draft.last_visited_step, 'zero side effects: last_visited_step must be untouched by the losing autosave'
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'application-field autosave commits first: the merge then proceeds normally, observing the autosaved value' do
      admin, canonical, duplicate, review_case = build_fixtures
      draft = create(:application, :draft, user: duplicate, household_size: 1)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      autosave_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          autosave_result = run_autosave_application_field(user: duplicate, application_id: draft.id)
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

      assert autosave_result[:success], "expected autosave (holder) to succeed: #{autosave_result.inspect}"
      assert merge_result.success?, "expected the merge to proceed normally once autosave committed: #{merge_result&.message}"
      assert_equal 4, draft.reload.household_size, "the autosaved value must survive on the retired duplicate's own application"
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'a draft that becomes submitted while autosave waits on the shared lock fails closed, never substituting another draft' do
      user = create(:constituent)
      draft = create(:application, :draft, user: user, household_size: 1)
      other_draft_never_touched = nil

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      submission_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          submission_result = run_submission(user:, application: draft)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      autosave_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        # If autosave fell back to find-or-create instead of failing closed on the exact
        # supplied id, this second draft is what it would silently substitute and write to.
        other_draft_never_touched = Application.create!(user: User.find(user.id), status: :draft,
                                                        application_date: Time.current, submission_method: :online)
        autosave_result = run_autosave_application_field(user:, application_id: draft.id)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert submission_result.success?, "expected the submission (holder) to succeed: #{submission_result.error_messages}"
      assert_equal 'in_progress', draft.reload.status
      assert_not autosave_result[:success], 'expected autosave to fail closed once the supplied draft was submitted underneath it'
      assert_includes autosave_result[:errors][:base], 'This application is no longer a draft.'
      # 2, not autosave's attempted 4: the committed submission's own form legitimately set
      # household_size to 2 as part of its real mutation -- the losing autosave's value must
      # simply never have landed on top of it.
      assert_equal 2, draft.reload.household_size, "zero side effects: autosave's own value must never overwrite the submission's"
      # 1, not 0: the committed submission's own real field changes legitimately log exactly
      # one application_updated event on their own -- the losing autosave must add none on top.
      assert_equal 1, Event.where(action: 'application_updated', auditable: draft).count
      assert_equal 'draft', other_draft_never_touched.reload.status,
                   'the other draft must never have been touched -- autosave must never substitute a different application'
      assert_nil other_draft_never_touched.household_size
    ensure
      other_draft_never_touched&.destroy
      draft&.destroy
      user&.destroy
    end

    test 'role conversion commits first: autosave fails the exact constituent-role recheck with zero writes' do
      user = create(:constituent, vision_disability: false, hearing_disability: true)
      draft = create(:application, :draft, user: user)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      conversion_response = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          conversion_response = run_role_conversion(user)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      autosave_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        autosave_result = run_autosave(user:, application_id: draft.id)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid,
        release_queue: release_holder,
        holder_thread: holder_thread,
        contender_thread: contender_thread
      )

      assert conversion_response[:success], conversion_response.inspect
      assert_not autosave_result[:success]
      assert_includes autosave_result[:errors][:base],
                      'Only constituent records can use the constituent application portal.'
      assert_not User.find(user.id).vision_disability?
      assert_nil draft.reload.last_visited_step
    ensure
      draft&.destroy
      User.find_by(id: user&.id)&.destroy
    end

    test 'autosave commits first: later role conversion observes the serialized portal write' do
      user = create(:constituent, vision_disability: false, hearing_disability: true)
      draft = create(:application, :draft, user: user)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      autosave_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          autosave_result = run_autosave(user:, application_id: draft.id)
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
        conversion_response = run_role_conversion(user)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid,
        release_queue: release_holder,
        holder_thread: holder_thread,
        contender_thread: contender_thread
      )

      assert autosave_result[:success], autosave_result.inspect
      assert conversion_response[:success], conversion_response.inspect
      assert User.find(user.id).vision_disability?
      assert_equal 'vision_disability', draft.reload.last_visited_step
      assert_equal 'Users::Administrator', User.find(user.id).type
    ensure
      draft&.destroy
      User.find_by(id: user&.id)&.destroy
    end

    private

    def build_fixtures
      admin = create(:admin)
      canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
      duplicate = nil
      begin
        Current.paper_context = true
        # No disability field is set explicitly: the :constituent factory's after(:build) hook
        # force-defaults hearing_disability to true whenever every disability flag would
        # otherwise be blank, so vision_disability (autosaved below) starts reliably false.
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

    def run_autosave(user:, application_id:)
      Applications::AutosaveService.new(
        current_user: User.find(user.id),
        params: {
          id: application_id,
          field_name: 'application[vision_disability]',
          field_value: 'true'
        }
      ).call
    end

    def run_autosave_application_field(user:, application_id:)
      Applications::AutosaveService.new(
        current_user: User.find(user.id),
        params: {
          id: application_id,
          field_name: 'application[household_size]',
          field_value: '4'
        }
      ).call
    end

    def run_submission(user:, application:)
      form = ApplicationForm.new(
        current_user: User.find(user.id),
        application: Application.find(application.id),
        annual_income: '50000',
        household_size: 2,
        submission_method: 'online',
        hearing_disability: false,
        vision_disability: true,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false,
        medical_provider_name: 'Test Provider',
        medical_provider_phone: '555-1234',
        medical_provider_email: 'provider@test.com',
        terms_accepted: true,
        information_verified: true,
        medical_release_authorized: true,
        is_submission: true
      )
      ApplicationCreator.call(form)
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
