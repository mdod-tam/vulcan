# frozen_string_literal: true

require 'zip'

module Icanconnect
  class DocumentPackage
    def self.build(prep, actor:)
      raise ArgumentError, 'Administrator required' unless actor.admin?

      attachments = prep.rows.flat_map(&:documents).uniq(&:blob_id)
      attachments.each do |attachment|
        raise ActiveRecord::RecordNotFound unless AttachmentAccess.new(attachment.blob).allowed?(actor)

        DocumentScan.require_clean!(attachment.blob)
      end
      result = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry('worksheet.csv')
        zip.write(prep.csv)
        attachments.each do |attachment|
          zip.put_next_entry(FilingPrep.document_reference(attachment))
          attachment.blob.download { |chunk| zip.write(chunk) }
        end
      end.string
      AuditEventService.log(action: 'export_generated', actor: actor,
                            metadata: { export_type: 'icanconnect_evidence', row_count: prep.rows.size, document_count: attachments.size })
      result
    end
  end
end
