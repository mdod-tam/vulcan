# frozen_string_literal: true

require 'test_helper'

module Applications
  # Two submissions of one person can interleave between the identity search and the create.
  # Each sees a clean search and creates, and neither request is stale.
  # PaperApplicationService prevents this with a transaction-scoped advisory lock on the identity.
  # Each test confirms the holder's backend blocks the contender before the holder releases.
  # Thus the result comes from real lock contention, not from thread timing.
  class PaperIdentityConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper
    include PaperIdentityConfirmationHelper

    setup do
      setup_active_storage_test
      setup_paper_application_context
      setup_fpl_policies
      @admin = create(:admin)
      # These tests commit. Random contact values prevent a collision with rows from an earlier run.
      @stamp = SecureRandom.hex(5)
      @phone_suffix = format('%<n>07d', n: SecureRandom.random_number(10_000_000))
      @seeded_ids = []
    end

    # The contact values are different on purpose. The unique email and phone indexes refuse
    # identical values, so a test with identical values passes without the lock.
    # Only the lock catches one person entered from two paper forms with different contact values.
    test 'two concurrent submissions of the same new applicant create exactly one' do
      outcomes = run_racing_creates(params_for: ->(index) { new_applicant_params(index) })

      assert_equal 1, outcomes.count { |outcome| outcome[:created] },
                   "exactly one submission may create: #{outcomes.inspect}"
      assert_equal 1, created_users.count
      assert_equal 1, Application.where(user_id: created_users.map(&:id)).count

      loser = outcomes.find { |outcome| !outcome[:created] }
      assert_predicate loser[:errors], :any?, 'the losing submission must say why it wrote nothing'
    ensure
      cleanup!
    end

    # With no email and no phone, two submissions can carry identical identity facts and one signed
    # decision. No unique index applies, and the stateless token alone cannot prevent a second spend.
    # The loser runs detection again under the lock and sees the winner's committed record.
    # Its decision then names a candidate set that no longer exists.
    test 'the same decision token cannot be spent twice concurrently' do
      candidate = create(:constituent, first_name: 'Race', last_name: 'Case',
                                       date_of_birth: Date.new(1980, 1, 15))
      @seeded_ids << candidate.id
      params = confirmed_paper_params(address_only_params, admin: @admin)
      assert params[:identity_review_receipt].present?, 'this test is only meaningful with a real decision'

      outcomes = run_racing_creates(params_for: ->(_index) { deep_dup_params(params) })

      assert_equal 1, outcomes.count { |outcome| outcome[:created] },
                   "one signed decision may be spent once: #{outcomes.inspect}"
      assert_equal 1, created_users.count
      assert_equal 1, Event.where(action: 'duplicate_review_case_resolved',
                                  auditable_type: 'User', auditable_id: created_users.map(&:id)).count,
                   'the override must be recorded once, not once per racing request'
    ensure
      cleanup!
    end

    # Different guardians and identities give the two requests different row and advisory locks.
    # Only the unique index on the shared dependent email serializes them. The loser must let
    # PostgreSQL roll back the aborted transaction. Then it must report an exact-contact block.
    test 'dependent contact collision after a unique-index race returns an actionable refusal' do
      @guardians = [
        create(:constituent, phone: "410555#{format('%04d', SecureRandom.random_number(10_000))}"),
        create(:constituent, phone: "301555#{format('%04d', SecureRandom.random_number(10_000))}")
      ]
      @seeded_ids.concat(@guardians.map(&:id))
      @shared_dependent_email = "dependent-race-#{@stamp}@example.com"

      outcomes = run_racing_creates(params_for: ->(index) { new_dependent_params(index) })

      assert_equal 1, outcomes.count { |outcome| outcome[:created] }, outcomes.inspect
      dependent = User.find_by_email(@shared_dependent_email)
      assert dependent, 'the winning dependent must own the submitted email'
      assert_equal 1, Application.where(user_id: dependent.id).count
      assert_equal 1, GuardianRelationship.where(dependent_id: dependent.id).count
      assert_equal 0, DuplicateReviewCase.where(subject_user_id: dependent.id).count
      assert_equal 0, Event.where(action: 'duplicate_review_case_resolved',
                                  auditable_type: 'User', auditable_id: dependent.id).count

      loser = outcomes.find { |outcome| !outcome[:created] }
      assert_includes loser[:errors],
                      GuardianDependentManagementService::DEPENDENT_CONTACT_COLLISION_MESSAGE
      assert_no_match(/index_users|duplicate key/i, loser[:errors].join(' '))
    ensure
      cleanup!
    end

    private

    # Excludes the seeded soft-match candidate, which has the same name and date of birth.
    def created_users
      Users::Constituent.where(first_name: 'Race', last_name: 'Case')
                        .where.not(id: @seeded_ids)
                        .to_a
    end

    def cleanup!
      users = Users::Constituent.where(first_name: 'Race', last_name: 'Case').to_a
      users.concat(User.unscoped.where(id: @seeded_ids).to_a)
      raced_dependent = User.find_by_email(@shared_dependent_email) if @shared_dependent_email.present?
      cleanup_duplicate_review_test_data!(*users, raced_dependent, @admin)
    end

    def new_dependent_params(index)
      {
        applicant_type: 'dependent',
        guardian_id: @guardians.fetch(index).id,
        relationship_type: 'Parent',
        email_strategy: 'dependent',
        phone_strategy: 'guardian',
        address_strategy: 'guardian',
        constituent: {
          first_name: "ContactRace#{index}",
          last_name: 'Dependent',
          date_of_birth: Date.new(2010 + index, 2, 3).iso8601,
          dependent_email: @shared_dependent_email,
          dependent_phone: '',
          hearing_disability: '1',
          vision_disability: '0',
          speech_disability: '0',
          mobility_disability: '0',
          cognition_disability: '0'
        },
        application: {
          household_size: '2',
          annual_income: '15000',
          maryland_resident: '1',
          self_certify_disability: '1',
          medical_provider_name: 'Dr. Smith',
          medical_provider_phone: '2025559876',
          medical_provider_email: 'drsmith@example.com'
        }
      }
    end

    def new_applicant_params(index = 0)
      {
        constituent: {
          first_name: 'Race',
          last_name: 'Case',
          date_of_birth: '1980-01-15',
          email: "race-#{@stamp}-#{index}@example.com",
          phone: "202#{format('%<n>07d', n: @phone_suffix.to_i + index)}",
          physical_address_1: '123 Test St',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          hearing_disability: '1',
          vision_disability: '0',
          speech_disability: '0',
          mobility_disability: '0',
          cognition_disability: '0'
        },
        application: {
          household_size: '2',
          annual_income: '15000',
          maryland_resident: '1',
          self_certify_disability: '1',
          medical_provider_name: 'Dr. Smith',
          medical_provider_phone: '2025559876',
          medical_provider_email: 'drsmith@example.com'
        }
      }
    end

    # Staff record no email and no phone. PaperContactFlags reads the flags from the top level,
    # not from the constituent hash.
    def address_only_params
      params = new_applicant_params
      params[:constituent] = params[:constituent].except(:email, :phone)
      params.merge(no_email_address: '1', no_phone_number: '1')
    end

    def deep_dup_params(params)
      Marshal.load(Marshal.dump(params))
    end

    # The holder runs the full create in an open transaction and keeps the identity lock.
    # The holder commits only after the contender is confirmed blocked by the holder's backend.
    def run_racing_creates(params_for: ->(_index) { new_applicant_params })
      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      outcomes = Array.new(2)

      holder_thread = on_own_connection do
        holder_pid_queue << backend_pid
        ActiveRecord::Base.transaction do
          outcomes[0] = run_create(params_for.call(0))
          holder_ready << true
          release_holder.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
      wait_for_signal(holder_ready, thread: holder_thread)

      contender_pid_queue = Queue.new
      contender_thread = on_own_connection do
        contender_pid_queue << backend_pid
        outcomes[1] = run_create(params_for.call(1))
      end

      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender_thread),
        holder_pid: holder_pid, release_queue: release_holder,
        holder_thread: holder_thread, contender_thread: contender_thread
      )

      outcomes
    end

    def run_create(params)
      Current.paper_context = true
      service = PaperApplicationService.new(params: params, admin: @admin)
      { created: service.create, errors: service.errors }
    ensure
      Current.reset
    end
  end
end
