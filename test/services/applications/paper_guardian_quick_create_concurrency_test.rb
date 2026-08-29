# frozen_string_literal: true

require 'test_helper'

module Applications
  # The quick-create JSON boundary is a separate canonical writer from PaperApplicationService.
  # These tests use real Postgres sessions and hold the winner's transaction open only long enough
  # to prove which database lock makes the competing production service call wait.
  class PaperGuardianQuickCreateConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    setup do
      @admin = create(:admin)
      @stamp = SecureRandom.hex(5)
      @race_first_names = []
    end

    test 'same-identity guardian quick-creates serialize and create exactly one guardian' do
      first_name = "IdentityRace#{@stamp}"
      @race_first_names << first_name
      attrs = 2.times.map do |index|
        quick_create_attrs(
          first_name: first_name,
          date_of_birth: '1980-01-15',
          email: "guardian-identity-race-#{@stamp}-#{index}@example.com"
        )
      end

      outcomes = run_racing_quick_creates(attrs)
      users = race_users

      assert_equal 1, outcomes.count { |outcome| outcome[:success] && outcome[:state] == :created }, outcomes.inspect
      assert_equal 1, users.size

      loser = outcomes.find { |outcome| !outcome[:success] }
      assert_equal :needs_confirmation, loser[:state]
      assert_equal [users.sole.id], loser[:candidate_ids]
      assert_match(/Review the possible matches/i, loser[:message])
      assert_no_workflow_side_effects(users)
    ensure
      cleanup!
    end

    test 'different-identity guardian quick-creates reclassify a unique-contact race after rollback' do
      first_names = ["ContactRaceA#{@stamp}", "ContactRaceB#{@stamp}"]
      @race_first_names.concat(first_names)
      shared_email = "guardian-contact-race-#{@stamp}@example.com"
      attrs = first_names.each_with_index.map do |first_name, index|
        quick_create_attrs(
          first_name: first_name,
          date_of_birth: Date.new(1980 + index, 1, 15).iso8601,
          email: shared_email
        )
      end

      outcomes = run_racing_quick_creates(attrs)
      users = race_users

      assert_equal 1, outcomes.count { |outcome| outcome[:success] && outcome[:state] == :created }, outcomes.inspect
      assert_equal 1, users.size

      loser = outcomes.find { |outcome| !outcome[:success] }
      assert_equal :blocked, loser[:state]
      assert_equal [users.sole.id], loser[:candidate_ids]
      assert_match(/already exists/i, loser[:message])
      assert_no_match(/index_users|duplicate key/i, loser[:message])
      assert_no_workflow_side_effects(users)
    ensure
      cleanup!
    end

    private

    def quick_create_attrs(first_name:, date_of_birth:, email:)
      {
        first_name: first_name,
        last_name: 'Guardian',
        date_of_birth: date_of_birth,
        email: email,
        phone: "301#{format('%07d', SecureRandom.random_number(10_000_000))}",
        physical_address_1: '4 Race Way',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201',
        communication_preference: 'email'
      }
    end

    def run_racing_quick_creates(attrs)
      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      outcomes = Array.new(2)

      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          outcomes[0] = run_quick_create(attrs.fetch(0))
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        outcomes[1] = run_quick_create(attrs.fetch(1))
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid,
        release_queue: release_holder,
        holder_thread: holder_thread,
        contender_thread: contender_thread
      )

      outcomes
    end

    def run_quick_create(attrs)
      Current.paper_context = true
      result = PaperGuardianQuickCreateService.new(
        attrs: attrs,
        request_params: attrs,
        admin: @admin
      ).call
      review = result.data.fetch(:review)
      {
        success: result.success?,
        state: result.data.fetch(:state),
        user_id: result.data[:user]&.id,
        candidate_ids: review.candidate_ids,
        message: result.message.to_s
      }
    ensure
      Current.reset
    end

    def race_users
      Users::Constituent.where(first_name: @race_first_names).order(:id).to_a
    end

    def assert_no_workflow_side_effects(users)
      ids = users.map(&:id)
      assert_equal 0, GuardianRelationship.where('guardian_id IN (?) OR dependent_id IN (?)', ids, ids).count
      assert_equal 0, Application.where('user_id IN (?) OR managing_guardian_id IN (?)', ids, ids).count
      assert_equal 0, DuplicateReviewCase.where(subject_user_id: ids).count
      assert_equal 0, DuplicateReviewCaseCandidate.where(candidate_user_id: ids).count
      assert_equal 1, Event.where(action: 'profile_created_by_admin_via_paper',
                                  auditable_type: 'User', auditable_id: ids).count
      assert_equal 0, Event.where(action: 'paper_identity_no_match_confirmed',
                                  auditable_type: 'User', auditable_id: ids).count
      assert_equal 0, Notification.where(recipient_id: ids).count
    end

    def cleanup!
      cleanup_duplicate_review_test_data!(*race_users, @admin)
    end
  end
end
