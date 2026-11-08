# frozen_string_literal: true

require 'test_helper'

module Users
  class RegistrationCompletionConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      @email = "registration-race-#{SecureRandom.hex(6)}@example.test"
      @proofs = [RegistrationVerification.create!(email: @email, locale: 'en', expires_at: 20.minutes.from_now)]
      @attributes = { first_name: 'Concurrent', last_name: SecureRandom.hex(6), date_of_birth: '01/15/1990',
                      password: 'password1234', password_confirmation: 'password1234', locale: 'en' }
    end

    teardown do
      users = User.where(email: @email).to_a
      RegistrationVerification.where(id: @proofs.map(&:id)).destroy_all
      cleanup_duplicate_review_test_data!(*users)
      Current.reset
    end

    test 'one proof cannot create two accounts when completion requests overlap' do
      first, second = complete_while_uncommitted(@proofs.first, @proofs.first)

      assert_equal :complete, first.status
      assert_equal :invalid, second.status
      assert_equal 1, User.where(email: @email).count
      assert_equal User.find_by_email(@email), @proofs.first.reload.created_user
    end

    test 'separate proofs for one email cannot overwrite the uniqueness winner' do
      @proofs << RegistrationVerification.create!(email: @email, locale: 'en', expires_at: 20.minutes.from_now)
      first, second = complete_while_uncommitted(*@proofs)

      assert_equal :complete, first.status
      assert_includes %i[existing failed validation_failed], second.status
      assert_equal 1, User.where(email: @email).count
      user = User.find_by_email(@email)
      assert user.authenticate('password1234')
      assert_equal user.id, @proofs.first.reload.created_user_id
      assert_nil @proofs.last.reload.created_user_id
    end

    test 'an after commit exception reports the account that actually committed' do
      raised_after_commit = false
      proof_id = @proofs.first.id
      callback = lambda do |record|
        next unless record.id == proof_id && record.created_user_id

        raised_after_commit = true
        raise 'Post-commit observer failed'
      end
      RegistrationVerification.set_callback(:commit, :after, callback)
      result = RegistrationCompletion.new(token: @proofs.first.proof_token, attributes: @attributes).call

      assert raised_after_commit
      assert_equal :complete, result.status
      assert_equal @proofs.first.reload.created_user_id, result.user.id
      assert User.exists?(result.user.id)
    ensure
      RegistrationVerification.skip_callback(:commit, :after, callback) if callback
    end

    test 'failed commit readback reports uncertainty without returning an unconfirmed user' do
      proof_id = @proofs.first.id
      callback = lambda do |record|
        next unless record.id == proof_id && record.created_user_id

        RegistrationVerification.any_instance.stubs(:reload).raises(ActiveRecord::ConnectionNotEstablished)
        raise 'Post-commit observer failed'
      end
      RegistrationVerification.set_callback(:commit, :after, callback)

      result = RegistrationCompletion.new(token: @proofs.first.proof_token, attributes: @attributes).call

      assert_equal :uncertain, result.status
      assert_nil result.user
      RegistrationVerification.any_instance.unstub(:reload)
      proof = RegistrationVerification.find(proof_id)
      assert proof.consumed_at
      assert_equal User.find_by_email(@email).id, proof.created_user_id
      assert_equal 1, User.where(email: @email).count
    ensure
      RegistrationVerification.any_instance.unstub(:reload)
      RegistrationVerification.skip_callback(:commit, :after, callback) if callback
    end

    private

    def complete_while_uncommitted(first_proof, second_proof)
      holder_ready = Queue.new
      holder_pids = Queue.new
      release = Queue.new
      first = nil
      holder = on_own_connection do
        holder_pids << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        ActiveRecord::Base.transaction do
          first = RegistrationCompletion.new(token: first_proof.proof_token, attributes: @attributes).call
          holder_ready << true
          release.pop
        end
      end
      holder_pid = wait_for_signal(holder_pids, thread: holder)
      wait_for_signal(holder_ready, thread: holder)
      contender_pids = Queue.new
      second = nil
      contender = on_own_connection do
        contender_pids << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        second = RegistrationCompletion.new(token: second_proof.proof_token,
                                            attributes: @attributes.merge(password: 'different-password', password_confirmation: 'different-password')).call
      end
      confirm_blocked_then_release(wait_for_signal(contender_pids, thread: contender), holder_pid: holder_pid,
                                                                                       release_queue: release, holder_thread: holder, contender_thread: contender)
      [first, second]
    end
  end
end
