# frozen_string_literal: true

require 'test_helper'

# Focused concurrency evidence for the primary contact/profile edit boundary (plan section 4,
# row 3): UsersController#update (self-service constituent profile edit) and the merge
# service must serialize through User.lock_for_merge_integrity! on the target user.
#
# Exercises the real, private controller method directly (via a minimal
# ActionDispatch::TestRequest/TestResponse pair, using set_request!/set_response! -- see
# passwords_controller_concurrency_test.rb for why -- and injecting current_user directly via
# @current_user, the same memoized ivar Authentication#current_user itself reads) rather than
# through routing. Both sides of every race are real production code.
class UsersControllerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'merge commits first: profile edit for the newly-merged duplicate fails closed with zero writes' do
    admin, canonical, duplicate, review_case = build_fixtures
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
      update_response = run_profile_edit(duplicate)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    assert merge_result.success?, "expected the merge (holder) to succeed: #{merge_result&.message}"
    assert_equal :redirect, update_response[:action]
    assert_match(/no longer eligible/i, update_response[:alert])
    assert_equal original_first_name, duplicate.reload.first_name, 'zero side effects: the merged duplicate must be untouched by the losing edit'
  ensure
    cleanup_duplicate_review_test_data!(admin, canonical, duplicate)
  end

  test 'profile edit commits first: the merge then proceeds normally' do
    admin, canonical, duplicate, review_case = build_fixtures

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    update_response = nil
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        update_response = run_profile_edit(duplicate)
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
    assert_equal 'Profile successfully updated', update_response[:notice]
    assert_equal 'Updated', duplicate.reload.first_name, 'the committed edit must have taken effect'
    assert merge_result.success?, "expected the merge to proceed normally once the profile edit committed: #{merge_result&.message}"
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

  def run_profile_edit(user)
    fresh_user = User.find(user.id)
    controller = UsersController.new
    controller.set_request!(ActionDispatch::TestRequest.create)
    controller.set_response!(ActionDispatch::TestResponse.new)
    controller.instance_variable_set(:@current_user, fresh_user)
    controller.params = ActionController::Parameters.new(
      user: { first_name: 'Updated', last_name: fresh_user.last_name, email: fresh_user.email,
              phone: fresh_user.phone, phone_type: fresh_user.phone_type }
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
