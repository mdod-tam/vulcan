# frozen_string_literal: true

require 'test_helper'

module Applications
  # The identity review reads the rows that exist now; the creation immediately afterwards adds one.
  # Two submissions of the same person that interleave between those two steps would each see a
  # clean search and each create -- a duplicate that no amount of client-side care prevents, because
  # neither request is stale and neither is wrong at the moment it looks.
  #
  # PaperApplicationService closes that with a transaction-scoped advisory lock keyed on the
  # identity. These tests are the evidence that it does, and that it is genuinely Postgres lock
  # contention doing it rather than the two threads happening not to overlap: the contender is
  # confirmed blocked *by the holder's backend* before the holder is released.
  class PaperIdentityConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper
    include PaperIdentityConfirmationHelper

    setup do
      setup_active_storage_test
      setup_paper_application_context
      setup_fpl_policies
      @admin = create(:admin)
      # Unique per run: these tests commit for real, so a timestamp-derived contact can collide with
      # a record an earlier run left behind and fail as a hard block rather than as a race.
      @stamp = SecureRandom.hex(5)
      @phone_suffix = format('%<n>07d', n: SecureRandom.random_number(10_000_000))
      @seeded_ids = []
    end

    # Deliberately different contact values on the two submissions. Identical ones are already
    # refused by the unique index on email and phone, so a test using them would pass with the lock
    # removed and prove nothing. The same person entered twice from two paper forms -- different
    # transcriber, different email on file -- is the case nothing else catches.
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

    # An applicant with neither email nor phone is the only way two submissions can carry *identical*
    # identity facts, and therefore the same signed decision: with no contact values there is no
    # unique index to collide on. So this is the case where the token is the only thing standing
    # between one override and two records -- and being stateless, it is not enough on its own.
    #
    # What actually stops the second creation is that the loser re-runs detection under the lock and
    # now sees the record the winner just committed, so the decision it carries was issued for a
    # candidate set that no longer exists.
    test 'the same decision token cannot be spent twice concurrently' do
      candidate = create(:constituent, first_name: 'Race', last_name: 'Case',
                                       date_of_birth: Date.new(1980, 1, 15))
      @seeded_ids << candidate.id
      params = confirmed_paper_params(address_only_params, admin: @admin)
      assert params[:identity_decision].present?, 'this test is only meaningful with a real decision'

      outcomes = run_racing_creates(params_for: ->(_index) { deep_dup_params(params) })

      assert_equal 1, outcomes.count { |outcome| outcome[:created] },
                   "one signed decision may be spent once: #{outcomes.inspect}"
      assert_equal 1, created_users.count
      assert_equal 1, Event.where(action: 'paper_identity_no_match_confirmed',
                                  auditable_type: 'User', auditable_id: created_users.map(&:id)).count,
                   'the override must be recorded once, not once per racing request'
    ensure
      cleanup!
    end

    # Different guardians mean the two requests lock different guardian rows; different names and
    # birth dates mean they also take different identity advisory locks. The shared own-email is
    # therefore the only point that can serialize these writers. The loser must let PostgreSQL roll
    # back the aborted transaction, then classify the committed winner as an exact-contact block.
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
      assert_equal 0, Event.where(action: 'paper_identity_no_match_confirmed',
                                  auditable_type: 'User', auditable_id: dependent.id).count

      loser = outcomes.find { |outcome| !outcome[:created] }
      assert_includes loser[:errors],
                      GuardianDependentManagementService::DEPENDENT_CONTACT_COLLISION_MESSAGE
      assert_no_match(/index_users|duplicate key/i, loser[:errors].join(' '))
    ensure
      cleanup!
    end

    private

    # Only the applicants these submissions created -- never the seeded soft-match candidate, which
    # shares the name and date of birth by design and would otherwise be counted as a creation.
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

    # Staff truthfully recording that this applicant has no email and no phone. The flags sit beside
    # the constituent hash, not inside it, because PaperContactFlags reads them from the top level.
    def address_only_params
      params = new_applicant_params
      params[:constituent] = params[:constituent].except(:email, :phone)
      params.merge(no_email_address: '1', no_phone_number: '1')
    end

    def deep_dup_params(params)
      Marshal.load(Marshal.dump(params))
    end

    # The holder opens a transaction, runs the whole create (taking the identity lock inside it),
    # and then *waits* while still holding it. The contender starts and is confirmed blocked by the
    # holder's backend before the holder commits, so the interleaving under test is the real one
    # rather than whatever the scheduler happened to produce.
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
