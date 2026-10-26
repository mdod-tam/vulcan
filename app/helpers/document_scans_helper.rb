# frozen_string_literal: true

module DocumentScansHelper
  def document_scan_for(document)
    preload_document_scans([document])[document_scan_blob_id(document)]
  end

  # File groups share one query, including files without a scan record.
  def preload_document_scans(documents)
    scans = @document_scan_status_by_blob ||= {}
    ids = documents.filter_map { |document| document_scan_blob_id(document) }.uniq - scans.keys
    if ids.any?
      scans.merge!(ids.index_with(nil))
      scans.merge!(DocumentScan.where(blob_id: ids).index_by(&:blob_id))
    end
    scans
  end

  private

  def document_scan_blob_id(document)
    case document
    when ActiveStorage::Blob then document.id
    when ActiveStorage::Attachment then document.blob_id
    else document.blob&.id
    end
  end
end
