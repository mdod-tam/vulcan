# frozen_string_literal: true

class DocumentScanJob < ApplicationJob
  self.enqueue_after_transaction_commit = true
  queue_as :default

  def perform(document_scan_id)
    scan = DocumentScan.find_by(id: document_scan_id)
    return unless scan

    work = scan.claim_work!
    if work
      begin
        result = perform_scan(scan, work)
        scan.complete_work!(token: work.token, result: result)
      rescue AttachmentScanner::Client::Failure => e
        scan.fail_work!(token: work.token, code: e.code, retryable: e.retryable)
      rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
        scan.fail_work!(token: work.token, code: 'stored_file_unavailable', retryable: false)
      end
    end
    scan.reload
    self.class.set(wait_until: scan.next_attempt_at).perform_later(scan.id) if scan.pending? && scan.dismissed_at.nil? && scan.next_attempt_at
  end

  private

  def perform_scan(scan, work)
    client = AttachmentScanner::Client.new(before_request: -> { scan.begin_provider_work!(token: work.token) })
    return client.fetch(work.provider_scan_id) if work.action == :poll

    work.blob.open do |file|
      client.submit(io: file, filename: "#{work.token}#{extension(work.blob.content_type)}", content_type: work.blob.content_type)
    end
  end

  def extension(content_type)
    { 'application/pdf' => '.pdf', 'image/jpeg' => '.jpg', 'image/png' => '.png' }.fetch(content_type, '.bin')
  end
end
