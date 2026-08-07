# frozen_string_literal: true

require 'test_helper'

module Applications
  # Focused concurrency evidence for the portal-final-submission boundary (plan section 4,
  # row 1): Applications::ApplicationCreator -- the real production path behind both the
  # `create` and existing-draft `update` actions (the dead `submit` action deleted earlier
  # this round never reached this code at all) -- and the merge service must serialize
  # through User.lock_for_merge_integrity! on the applicant.
  class ApplicationCreatorConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    test 'merge commits first: submission for the newly-merged duplicate fails closed with zero lifecycle side effects' do
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
      submission_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        submission_result = run_submission(user: duplicate, application: draft)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
      assert_not submission_result.success?, 'expected the submission to fail closed once the applicant was merged'
      assert_includes submission_result.error_messages, 'This record is no longer an eligible active record.'
      draft.reload
      assert_equal 'draft', draft.status, 'zero side effects: the draft must not have transitioned to in_progress'
      assert_equal 0, Event.where(action: 'application_status_changed', auditable: draft).count
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    # The canonical submits here, not the duplicate. The duplicate is the subject of the open
    # registration_soft_match case, and the PR5a pending-review gate blocks final submission for
    # that subject until staff resolve it -- so "the subject submits, then a merge transfers that
    # submission" is no longer a reachable flow. The canonical is still a merge participant (its
    # application inventory is locked by the merge) and is never gated merely for being the matched
    # candidate, so it proves the same ordering: the submission commits first, the merge waits on
    # the shared rows, and the duplicate's separate application still transfers.
    test 'submission commits first: the merge then proceeds normally, transferring the duplicate application' do
      admin, canonical, duplicate, review_case = build_fixtures
      draft = create(:application, :draft, user: canonical)
      # Archived, so the merge does not refuse for leaving the survivor with two active
      # applications -- the transfer is what this asserts, not the eligibility policy.
      duplicate_application = create(:application, :archived, user: duplicate)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      submission_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          submission_result = run_submission(user: canonical, application: draft)
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

      assert submission_result.success?, "expected the submission (holder) to succeed: #{submission_result.error_messages}"
      assert_equal 'in_progress', draft.reload.status
      assert merge_result.success?, "expected the merge to proceed normally once the submission committed: #{merge_result&.message}"
      assert_equal canonical.id, draft.reload.user_id, 'the canonical keeps the application it just submitted'
      assert_equal canonical.id, duplicate_application.reload.user_id,
                   "the duplicate's application must have transferred to the canonical survivor"
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    test 'simultaneous submissions serialize on the exact draft and create lifecycle side effects once' do
      user = create(:constituent)
      draft = create(:application, :draft, user: user)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      first_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          first_result = run_submission(user:, application: draft, attach_income_proof: true)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      second_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        second_result = run_submission(user:, application: draft, attach_income_proof: true)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid,
        release_queue: release_holder,
        holder_thread: holder_thread,
        contender_thread: contender_thread
      )

      assert first_result.success?, first_result.error_messages.inspect
      assert second_result.failure?, 'the second submit must requalify the exact locked row and fail'
      assert_includes second_result.error_messages, 'This application is no longer a draft.'
      assert_equal 'in_progress', draft.reload.status
      assert_equal 1, ApplicationStatusChange.where(application: draft).count
      assert_equal 1, Event.where(action: 'application_status_changed', auditable: draft).count
      assert_equal 1, Event.where(action: 'application_updated', auditable: draft).count
      assert_equal 0, Notification.where(notifiable: draft).count
      assert_equal 1, ActiveStorage::Attachment.where(record: draft, name: 'income_proof').count
    ensure
      draft&.destroy
      user&.destroy
    end

    test 'submission commits first: a stale save-draft fails closed without undoing lifecycle state' do
      user = create(:constituent, hearing_disability: false, vision_disability: true)
      draft = create(:application, :draft, user: user, annual_income: 10_000, household_size: 1)

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
      draft_save_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        draft_save_result = run_draft_save(user:, application: draft)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid,
        release_queue: release_holder,
        holder_thread: holder_thread,
        contender_thread: contender_thread
      )

      assert submission_result.success?, submission_result.error_messages.inspect
      assert draft_save_result.failure?, 'the stale save-draft must requalify the exact locked row and fail'
      assert_includes draft_save_result.error_messages, 'This application is no longer a draft.'
      assert_equal 'in_progress', draft.reload.status
      assert_equal 2, draft.household_size, 'the losing save-draft must not overwrite the submitted application'
      assert_equal 50_000, draft.annual_income
      assert_not user.reload.hearing_disability, 'the losing save-draft must not mutate participant fields'
      assert user.vision_disability
      assert_equal 1, ApplicationStatusChange.where(application: draft).count
      assert_equal 1, Event.where(action: 'application_status_changed', auditable: draft).count
      assert_equal 1, Event.where(action: 'application_updated', auditable: draft).count
    ensure
      draft&.destroy
      user&.destroy
    end

    test 'save-draft commits first: a waiting submission proceeds through the canonical lifecycle once' do
      user = create(:constituent, hearing_disability: false, vision_disability: true)
      draft = create(:application, :draft, user: user, annual_income: 10_000, household_size: 1)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      draft_save_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          draft_save_result = run_draft_save(user:, application: draft)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      submission_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        submission_result = run_submission(user:, application: draft)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid,
        release_queue: release_holder,
        holder_thread: holder_thread,
        contender_thread: contender_thread
      )

      assert draft_save_result.success?, draft_save_result.error_messages.inspect
      assert submission_result.success?, submission_result.error_messages.inspect
      assert_equal 'in_progress', draft.reload.status
      assert_equal 2, draft.household_size
      assert_equal 50_000, draft.annual_income
      assert_equal 1, ApplicationStatusChange.where(application: draft).count
      assert_equal 1, Event.where(action: 'application_status_changed', auditable: draft).count
      assert_equal 1, Event.where(action: 'application_updated', auditable: draft).count,
                   'rapid draft and submission updates share the existing audit deduplication window'
    ensure
      draft&.destroy
      user&.destroy
    end

    test 'role conversion commits first: final submission fails the exact constituent-role recheck' do
      user = create(:constituent)
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
      submission_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        submission_result = run_submission(user:, application: draft)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid,
        release_queue: release_holder,
        holder_thread: holder_thread,
        contender_thread: contender_thread
      )

      assert conversion_response[:success], conversion_response.inspect
      assert submission_result.failure?
      assert_includes submission_result.error_messages,
                      'Only constituent records can use the constituent application portal.'
      assert_equal 'draft', draft.reload.status
      assert_equal 0, ApplicationStatusChange.where(application: draft).count
    ensure
      draft&.destroy
      User.find_by(id: user&.id)&.destroy
    end

    test 'final submission commits first: later role conversion observes the serialized portal write' do
      user = create(:constituent)
      draft = create(:application, :draft, user: user)

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

      assert submission_result.success?, submission_result.error_messages.inspect
      assert conversion_response[:success], conversion_response.inspect
      assert_equal 'in_progress', draft.reload.status
      assert_equal 1, ApplicationStatusChange.where(application: draft).count
      assert_equal 'Users::Administrator', User.find(user.id).type
    ensure
      draft&.destroy
      User.find_by(id: user&.id)&.destroy
    end

    # The pending-review gate reads the case without taking a lock of its own, on the argument that
    # this transaction already holds the applicant's User row and every writer that can resolve a
    # case -- DuplicateReviewCases::ResolutionService and Users::DuplicateMergeService -- acquires
    # that same row first. That argument is load-bearing, so prove it rather than assert it: the
    # submission must physically block on the resolution, and must then observe the committed
    # outcome rather than the state it would have read a moment earlier.
    test 'resolution commits first: the previously gated submission then blocks, sees it, and succeeds' do
      admin, canonical, duplicate, review_case = build_fixtures
      draft = create(:application, :draft, user: duplicate)

      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      resolution_result = nil
      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          resolution_result = run_keep_separate(admin: admin, review_case: review_case)
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      submission_result = nil
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        submission_result = run_submission(user: duplicate, application: draft)
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
      )

      assert resolution_result.success?, "expected the resolution (holder) to succeed: #{resolution_result&.message}"
      assert submission_result.success?,
             "the submission must observe the committed resolution and proceed: #{submission_result&.error_messages}"
      assert_equal 'in_progress', draft.reload.status
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    # The mirror case is deliberately sequential, not a lock race: a gated submission raises and
    # rolls back, so it holds nothing for a resolution to contend with. What matters is that the
    # refusal is not retroactive -- it stands, leaves no side effects, and a later resolution then
    # lets a fresh submission through.
    test 'submission refused first: the refusal stands and a later resolution unblocks it' do
      admin, canonical, duplicate, review_case = build_fixtures
      draft = create(:application, :draft, user: duplicate)

      refused = run_submission(user: duplicate, application: draft)
      assert refused.failure?, 'an open registration soft match must gate the subject'
      assert_equal 'draft', draft.reload.status, 'a refused submission leaves the draft untouched'

      assert run_keep_separate(admin: admin, review_case: review_case).success?

      allowed = run_submission(user: duplicate, application: draft)
      assert allowed.success?, "resolution must clear the gate: #{allowed&.error_messages}"
      assert_equal 'in_progress', draft.reload.status
    ensure
      cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
    end

    private

    def run_keep_separate(admin:, review_case:)
      DuplicateReviewCases::ResolutionService.new(
        duplicate_review_case: DuplicateReviewCase.find(review_case.id),
        actor: User.find(admin.id),
        rationale: 'confirmed different people',
        reason_codes: %w[exact_phone]
      ).call
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

    def run_submission(user:, application:, attach_income_proof: false)
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
        income_proof: submission_income_proof(attach_income_proof),
        is_submission: true
      )
      ApplicationCreator.call(form)
    end

    def run_draft_save(user:, application:)
      form = ApplicationForm.new(
        current_user: User.find(user.id),
        application: Application.find(application.id),
        annual_income: '62000',
        household_size: 4,
        submission_method: 'online',
        hearing_disability: true,
        vision_disability: false,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false,
        medical_provider_name: 'Draft Provider',
        medical_provider_phone: '555-4321',
        medical_provider_email: 'draft-provider@test.com',
        terms_accepted: true,
        information_verified: true,
        medical_release_authorized: true,
        is_submission: false
      )
      ApplicationCreator.call(form)
    end

    def submission_income_proof(attach)
      return unless attach

      Rack::Test::UploadedFile.new(
        Rails.root.join('test/fixtures/files/income_proof.pdf'),
        'application/pdf'
      )
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
