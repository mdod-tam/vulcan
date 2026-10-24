# frozen_string_literal: true

module DocumentSigning
  class AcceptScannedDocumentJob < ApplicationJob
    self.enqueue_after_transaction_commit = true
    queue_as :default

    def perform(scan_id)
      scan = DocumentScan.find_by(id: scan_id)
      return unless scan

      claim = scan.claim_continuation!
      if claim == :exhausted
        AcceptScannedDocument.give_up(scan, error_code: scan.continuation_error_code || 'continuation_worker_interrupted')
      elsif claim == :claimed
        accept(scan)
      end
    end

    private

    def accept(scan)
      AcceptScannedDocument.call(scan)
    rescue StandardError => e
      # The transaction may have committed before an after_commit error. A failed
      # readback propagates; it cannot establish rollback or justify another attempt.
      scan.reload
      return if scan.continued_at

      error_code = e.is_a?(AcceptScannedDocument::AcceptanceFailed) ? e.code : e.class.name
      permanent = e.is_a?(AcceptScannedDocument::AcceptanceFailed) || e.is_a?(ActiveRecord::RecordNotFound)
      if permanent || scan.continuation_attempts >= DocumentScan::Continuation::MAX_CONTINUATION_ATTEMPTS
        AcceptScannedDocument.give_up(scan, error_code: error_code)
      else
        retry_at = scan.retry_continuation!(error_code: error_code)
        self.class.set(wait_until: retry_at).perform_later(scan.id) if retry_at
      end
    end
  end
end
