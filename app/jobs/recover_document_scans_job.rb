# frozen_string_literal: true

class RecoverDocumentScansJob < ApplicationJob
  queue_as :low

  def perform
    DocumentScan.pending.where(created_at: ..DocumentScan::Work::RESOLUTION_WINDOW.ago).find_each(&:expire_unresolved!)
    DocumentScan.due_for_work.order(:id).limit(100).pluck(:id).each { |id| DocumentScanJob.perform_later(id) }
    DocumentScan.clean.where(continuation: 'docuseal', continued_at: nil).order(:id).limit(100).pluck(:id).each do |id|
      DocumentSigning::AcceptScannedDocumentJob.perform_later(id)
    end
    backlog = DocumentScan.pending.where(created_at: ...15.minutes.ago).count
    Rails.event.notify('document_scan.backlog', count: backlog) if backlog.positive?
  end
end
