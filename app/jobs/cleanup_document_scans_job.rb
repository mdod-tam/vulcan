# frozen_string_literal: true

class CleanupDocumentScansJob < ApplicationJob
  RETENTION = 7.days
  queue_as :low

  def perform
    DocumentScan.where.not(status: 'pending').where(created_at: ...RETENTION.ago).find_each do |scan|
      blob = scan.blob
      blob.with_lock do
        scan.with_lock do
          unless scan.pending? || blob.attachments.exists?
            scan.destroy!
            ActiveRecord::Base.current_transaction.after_commit { blob.purge }
          end
        end
      end
    rescue ActiveRecord::RecordNotFound
      # Intake or another cleanup worker already removed this snapshot.
      next
    end
  end
end
