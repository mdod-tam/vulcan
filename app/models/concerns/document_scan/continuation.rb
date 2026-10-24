# frozen_string_literal: true

class DocumentScan
  module Continuation
    extend ActiveSupport::Concern

    MAX_CONTINUATION_ATTEMPTS = 3
    CONTINUATION_LEASE = 5.minutes

    included do
      scope :due_for_continuation, lambda {
        ready = where(continuation: 'docuseal', continued_at: nil).where.not(status: 'pending')
        ready.where('continuation_next_attempt_at IS NULL OR continuation_next_attempt_at <= ?', Time.current)
      }
    end

    # Reserve before acceptance so concurrent jobs and worker crashes share one retry budget.
    def claim_continuation!
      with_lock do
        if continuation == 'docuseal' && !pending? && continued_at.nil? &&
           (continuation_next_attempt_at.nil? || continuation_next_attempt_at <= Time.current)
          if continuation_attempts >= MAX_CONTINUATION_ATTEMPTS
            :exhausted
          else
            update!(continuation_attempts: continuation_attempts + 1, continuation_next_attempt_at: CONTINUATION_LEASE.from_now)
            :claimed
          end
        end
      end
    end

    def retry_continuation!(error_code:)
      with_lock do
        unless continued_at
          delay = continuation_attempts == 1 ? 1.minute : 5.minutes
          update!(continuation_error_code: error_code, continuation_next_attempt_at: delay.from_now)
          continuation_next_attempt_at
        end
      end
    end
  end
end
