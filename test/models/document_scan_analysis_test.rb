# frozen_string_literal: true

require 'test_helper'

class DocumentScanAnalysisTest < ActiveSupport::TestCase
  setup do
    @blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('disability_certification_valid.pdf').open,
                                                   filename: 'certification.pdf', content_type: 'application/pdf')
    mark_document_clean!(@blob, purpose: :certification, slot: 'disability_certification')
  end

  test 'direct synchronous and queued analysis reject every uncleared state' do
    scan = DocumentScan.find_by!(blob_id: @blob.id)
    %w[pending blocked failed].each do |status|
      scan.update!(status: status)
      @blob.expects(:extract_metadata_via_analyzer).never
      @blob.analyze
      ActiveStorage::AnalyzeJob.perform_now(@blob)
      assert_not @blob.reload.analyzed?
    end

    scan.destroy!
    @blob.analyze
    assert_not @blob.reload.analyzed?
  end

  test 'cleared documents retain the normal Rails analysis path' do
    @blob.analyze_later
    assert @blob.reload.analyzed?
  end
end
