# frozen_string_literal: true

require 'test_helper'

class DocumentScanCapacityJobTest < ActiveSupport::TestCase
  class ProviderTransport
    Response = Data.define(:code, :headers, :body)

    attr_reader :request_times

    def initialize(sha256:, byte_size:)
      @sha256 = sha256
      @byte_size = byte_size
      @poll_counts = Hash.new(0)
      @request_times = []
    end

    def timeout(**) = self

    def request(method, url, **)
      @request_times << Time.current
      id = method == :post ? SecureRandom.uuid : url.split('/').last
      @poll_counts[id] += 1 if method == :get
      status = @poll_counts[id] >= 3 ? 'ok' : 'pending'
      body = JSON.generate(id: id, status: status, sha256: @sha256, content_length: @byte_size)
      yield Response.new(code: 200, headers: {}, body: [body])
    end
  end

  test 'fifty simultaneous uploads finish after three polls without queue-induced expiry' do
    freeze_time do
      started_at = Time.current
      scans, transport = prepare_burst
      # This advances only the limiter's waits; the real job/client/budget still run.
      DocumentScanProviderBudget.stubs(:sleep).with do |delay|
        travel delay
        true
      end

      10_000.times do
        break unless DocumentScan.where(id: scans.map(&:id)).pending.exists?

        scan = DocumentScan.due_for_work.order(:next_attempt_at, :id).first
        if scan
          DocumentScanJob.perform_now(scan.id)
        else
          travel_to(DocumentScan.pending.minimum(:next_attempt_at))
        end
      end

      assert_equal 50, DocumentScan.where(id: scans.map(&:id)).clean.count
      assert_equal 200, transport.request_times.size
      assert_operator Time.current - started_at, :<, 30.minutes
      transport.request_times.each do |start|
        assert_operator transport.request_times.count { |time| time >= start && time < start + 1.minute }, :<=, 10
      end
    end
  end

  private

  def prepare_burst
    user = create(:admin)
    bytes = 'immutable queued document'
    sha256 = Digest::SHA256.hexdigest(bytes)
    scans = Array.new(50) do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: 'proof.pdf', content_type: 'application/pdf')
      DocumentScan.create!(blob: blob, user: user, purpose: 'proof', slot: 'income_proof', sha256: sha256, next_attempt_at: Time.current)
    end
    configuration = AttachmentScanner::Configuration.new(url: 'https://us-east-1.attachmentscanner.com', token: 'synthetic-token')
    Rails.application.config.x.stubs(:attachment_scanner).returns(configuration)
    transport = ProviderTransport.new(sha256: sha256, byte_size: bytes.bytesize)
    HTTP.stubs(:auth).returns(transport)
    [scans, transport]
  end
end
