# frozen_string_literal: true

require 'test_helper'

class DocumentScanJobTest < ActiveSupport::TestCase
  setup do
    user = create(:constituent)
    bytes = 'immutable scanned bytes'
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: 'sensitive-name.pdf', content_type: 'application/pdf')
    @scan = DocumentScan.create!(blob: blob, user: user, purpose: 'proof', slot: 'income_proof', sha256: Digest::SHA256.hexdigest(bytes),
                                 next_attempt_at: Time.current)
    @client = mock('attachment scanner')
    AttachmentScanner::Client.stubs(:new).returns(@client)
  end

  test 'job submits only stored snapshot bytes and a clean result makes them available' do
    @client.expects(:submit).with do |io:, filename:, content_type:|
      io.read == 'immutable scanned bytes' && filename.match?(/\A[0-9a-f-]{36}\.pdf\z/) && content_type == 'application/pdf'
    end.returns(result('ok'))

    DocumentScanJob.perform_now(@scan.id)

    assert @scan.reload.clean?
    assert_equal 1, @scan.attempts
    assert DocumentScan.cleared?(@scan.blob)
  end

  test 'provider credential failure is recorded without making the file available' do
    @client.expects(:submit).raises(AttachmentScanner::Client::Failure.new(:unauthorized))

    DocumentScanJob.perform_now(@scan.id)

    assert @scan.reload.failed?
    assert_equal 'unauthorized', @scan.last_error_code
    assert_not DocumentScan.cleared?(@scan.blob)
  end

  test 'transient failure remains blocked and schedules a bounded retry' do
    freeze_time do
      @scan.update!(next_attempt_at: Time.current)
      @client.expects(:submit).raises(AttachmentScanner::Client::Failure.new(:transport_error, retryable: true))

      DocumentScanJob.perform_now(@scan.id)

      assert @scan.reload.pending?
      assert_equal 'transport_error', @scan.last_error_code
      assert_equal 30.seconds.from_now, @scan.next_attempt_at
      assert_not DocumentScan.cleared?(@scan.blob)
    end
  end

  private

  def result(status)
    AttachmentScanner::Client::Result.new(status: status, scan_id: '0e25dd32-2f60-4cec-b449-1eca2fd48f00', sha256: @scan.sha256, byte_size: @scan.blob.byte_size)
  end
end
