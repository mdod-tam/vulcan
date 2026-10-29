# frozen_string_literal: true

module Applications
  # Tells a reviewer what became of its transaction when an error escapes it.
  #
  # The reviewer passes a reader that returns the durable facts its review writes, read from the database. The
  # reader runs before the writes, inside the transaction after them, and again after an error escapes.
  # Matching the in-transaction facts proves the commit. Matching the starting facts proves the rollback.
  # Anything else leaves the outcome unknown: a failed read, a half match, or a review that changed nothing
  # and so proves nothing.
  #
  # A transaction the caller already holds owns the commit, so nothing is judged there and the error propagates.
  class ReviewCommit
    # The database could not say whether the review committed.
    class Unconfirmed < StandardError; end

    attr_reader :warning

    # @param application [Application] named in log lines
    # @param subject [String] what messages call the review, such as "proof review"
    # @param again [String] the retry that messages warn against, such as "reviewing it again"
    # @yield [] returns a Hash of the durable facts the review writes
    def initialize(application:, subject:, again:, &read_state)
      @application = application
      @subject = subject
      @again = again
      @read_state = read_state
    end

    # Opens the transaction for the review's writes, with the facts read before and after them.
    # The reader runs on the writer connection. No reader role is configured. If one is added, keep it there so
    # replica lag cannot report a stale rollback.
    def transaction
      @previous = @read_state.call
      ApplicationRecord.transaction do
        value = yield
        @expected = @read_state.call
        value
      end
    end

    # Runs the review, including steps after its transaction.
    #
    # @param on_committed [#call] receives the error when the review committed but a later step failed.
    #   It must not raise.
    # @return the block's value; nil when the review committed and on_committed ran, with #warning set
    # @raise [Unconfirmed] when the database cannot say whether the review committed
    # @raise the original error when the review rolled back, or when the caller's transaction owns the commit
    def run(on_committed:)
      @warning = nil
      @previous = @expected = nil
      owns_commit = !ApplicationRecord.connection.current_transaction.joinable?
      yield
    rescue StandardError => e
      raise unless owns_commit

      Rails.logger.error "#{@subject.capitalize} failed: #{e.class.name} for application #{@application.id}"
      case state
      when :committed
        @warning = "The #{@subject} was saved, but a follow-up step did not finish. Check this application before #{@again}."
        on_committed.call(e)
        nil
      when :unknown
        raise Unconfirmed, "The #{@subject} may have been saved, but that could not be confirmed. Check this application before #{@again}."
      else
        raise
      end
    end

    private

    # @return [Symbol] :committed, :rolled_back, or :unknown
    def state
      return :rolled_back unless @expected
      return :unknown if @expected == @previous

      current = @read_state.call
      return :committed if current == @expected

      current == @previous ? :rolled_back : :unknown
    rescue StandardError => e
      Rails.logger.error "Could not confirm #{@subject} commit for Application #{@application.id}: #{e.class.name}"
      :unknown
    end
  end
end
