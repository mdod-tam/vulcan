# frozen_string_literal: true

module DocumentSigning
  class AcceptScannedDocumentJob < ApplicationJob
    self.enqueue_after_transaction_commit = true
    queue_as :default
    retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3
    discard_on ActiveRecord::RecordNotFound, DocumentScan::NotCleared

    def perform(scan_id)
      scan = DocumentScan.find(scan_id)
      AcceptScannedDocument.call(scan)
    end
  end
end
