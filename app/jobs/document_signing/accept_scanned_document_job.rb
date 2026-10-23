# frozen_string_literal: true

module DocumentSigning
  class AcceptScannedDocumentJob < ApplicationJob
    queue_as :default
    retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3
    discard_on ActiveRecord::RecordNotFound, DocumentScan::NotCleared

    def perform(scan_id)
      scan = DocumentScan.find(scan_id)
      outcome = AcceptScannedDocument.call(scan)
      scan.update!(continued_at: Time.current) if %i[completed superseded].include?(outcome)
    end
  end
end
