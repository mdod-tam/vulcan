# frozen_string_literal: true

require 'test_helper'

module Applications
  # ReviewCommit decides what an escaped error means for a review's transaction. The reviewers that use it
  # have their own tests for what they write.
  class ReviewCommitTest < ActiveSupport::TestCase
    setup do
      @facts = { saved: false }
      @reads = 0
      @commit = ReviewCommit.new(application: stub(id: 42), subject: 'proof review', again: 'reviewing it again') do
        @reads += 1
        @facts.dup
      end
      @follow_ups = []
    end

    test 'a review that finishes returns its value and leaves no warning' do
      value = run_review { @commit.transaction { write_facts && :written } }

      assert_equal :written, value
      assert_nil @commit.warning
      assert_empty @follow_ups
    end

    test 'an error before the writes finish is a rollback, so the original error propagates' do
      error = assert_raises(RuntimeError) { run_review { @commit.transaction { raise 'write failed' } } }

      assert_equal 'write failed', error.message
      assert_nil @commit.warning
      assert_empty @follow_ups
    end

    test 'an error after the commit returns nil with a warning and hands the error to the follow-up' do
      value = run_review do
        @commit.transaction { write_facts }
        raise 'callback failed'
      end

      assert_nil value
      assert_equal 'The proof review was saved, but a follow-up step did not finish. Check this application before reviewing it again.',
                   @commit.warning
      assert_equal ['callback failed'], @follow_ups.map(&:message)
    end

    test 'writes that are gone after the error are a rollback' do
      rolled_back = lambda do |*, &block|
        block.call
        @facts = { saved: false }
        raise 'commit failed'
      end

      error = ApplicationRecord.stub(:transaction, rolled_back) do
        assert_raises(RuntimeError) { run_review { @commit.transaction { write_facts } } }
      end

      assert_equal 'commit failed', error.message
      assert_nil @commit.warning
      assert_empty @follow_ups
    end

    test 'facts that match neither side leave the commit unconfirmed' do
      changed_elsewhere = lambda do |*, &block|
        block.call
        @facts = { saved: :something_else }
        raise 'commit failed'
      end

      error = ApplicationRecord.stub(:transaction, changed_elsewhere) do
        assert_raises(ReviewCommit::Unconfirmed) { run_review { @commit.transaction { write_facts } } }
      end

      assert_equal 'The proof review may have been saved, but that could not be confirmed. Check this application before reviewing it again.',
                   error.message
      assert_empty @follow_ups
    end

    test 'a failed read leaves the commit unconfirmed' do
      commit = ReviewCommit.new(application: stub(id: 42), subject: 'proof review', again: 'reviewing it again') do
        @reads += 1
        raise ActiveRecord::ConnectionNotEstablished, 'verification unavailable' if @reads > 2

        @facts.dup
      end

      assert_raises(ReviewCommit::Unconfirmed) do
        commit.run(on_committed: ->(error) { @follow_ups << error }) do
          commit.transaction { write_facts }
          raise 'callback failed'
        end
      end
      assert_empty @follow_ups
    end

    test 'a review that changed nothing cannot prove it committed' do
      assert_raises(ReviewCommit::Unconfirmed) do
        run_review do
          @commit.transaction { :nothing_written }
          raise 'callback failed'
        end
      end
      assert_empty @follow_ups
    end

    test 'inside the caller transaction no verdict is given and the error propagates' do
      error = assert_raises(RuntimeError) do
        ApplicationRecord.transaction do
          run_review do
            @commit.transaction { write_facts }
            raise 'callback failed'
          end
        end
      end

      assert_equal 'callback failed', error.message
      assert_nil @commit.warning
      assert_empty @follow_ups
      assert_equal 2, @reads, 'only the before and after reads run; the caller owns the commit'
    end

    test 'a second run starts without the first run warning or facts' do
      run_review do
        @commit.transaction { write_facts }
        raise 'callback failed'
      end
      assert @commit.warning

      value = run_review { :clean }

      assert_equal :clean, value
      assert_nil @commit.warning
    end

    private

    def write_facts
      @facts = { saved: true }
    end

    def run_review(&)
      @commit.run(on_committed: ->(error) { @follow_ups << error }, &)
    end
  end
end
