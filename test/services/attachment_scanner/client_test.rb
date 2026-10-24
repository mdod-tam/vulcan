# frozen_string_literal: true

require 'bundler/setup'
require 'active_support/test_case'
require 'active_support/core_ext/numeric/bytes'
require 'minitest/autorun'
require 'mocha/minitest'
require 'stringio'
require_relative '../../../app/services/attachment_scanner/configuration'
require_relative '../../../app/services/attachment_scanner/client'

class AttachmentScannerClientTest < ActiveSupport::TestCase
  SCAN_ID = '0e25dd32-2f60-4cec-b449-1eca2fd48f00'
  Response = Data.define(:code, :headers, :body)

  setup do
    @configuration = AttachmentScanner::Configuration.new(url: 'https://us-east-1.attachmentscanner.com', token: 'synthetic-token')
    @budget = mock('HTTP request budget')
    @budget.stubs(:wait_for_slot!)
    @client = AttachmentScanner::Client.new(configuration: @configuration, budget: @budget)
    @transport = mock('scanner transport')
    HTTP.stubs(:auth).with('Bearer synthetic-token').returns(@transport)
    @transport.stubs(:timeout).with(connect: 5, write: 30, read: 35, global: 45).returns(@transport)
  end

  test 'multipart submits exact bytes with an opaque filename and returns the verified fields' do
    io = StringIO.new('synthetic document')
    @transport.expects(:request).with do |verb, url, **options|
      file = options.fetch(:form).fetch(:file)
      verb == :post && url == 'https://us-east-1.attachmentscanner.com/v1.0/scans' &&
        options.fetch(:form).fetch(:async) == 'true' && file.filename == 'opaque-attempt.pdf' && file.read == 'synthetic document'
    end.yields(response('ok'))

    result = @client.submit(io: io, filename: 'opaque-attempt.pdf', content_type: 'application/pdf')

    assert_equal 'ok', result.status
    assert_equal SCAN_ID, result.scan_id
    assert_equal 'a' * 64, result.sha256
    assert_equal 18, result.byte_size
  end

  test 'polling uses a validated provider ID and accepts the documented blocked and pending results' do
    %w[pending found warning failed].each do |status|
      @transport.expects(:request).with(:get, "https://us-east-1.attachmentscanner.com/v1.0/scans/#{SCAN_ID}").yields(response(status))
      assert_equal status, @client.fetch(SCAN_ID).status
    end
    assert_raises(AttachmentScanner::Client::Failure) { @client.fetch('../other-scanner') }
  end

  test 'unknown verdicts and invalid clean identity cannot be accepted' do
    [response('unexpected'), response('ok', sha256: nil), response('ok', content_length: '18'), response('pending', sha256: [])].each do |received|
      @transport.expects(:request).yields(received)
      error = assert_raises(AttachmentScanner::Client::Failure) { @client.fetch(SCAN_ID) }
      assert_equal 'invalid_response', error.code
      assert_not error.retryable
    end
  end

  test 'configuration and subscription failures are terminal while throttles and transport failures can retry' do
    { 401 => ['unauthorized', false], 402 => ['subscription_expired', false], 429 => ['rate_limited', true], 503 => ['provider_error', true] }.each do |status, expected|
      @transport.expects(:request).yields(Response.new(code: status, headers: {}, body: []))
      error = assert_raises(AttachmentScanner::Client::Failure) { @client.fetch(SCAN_ID) }
      assert_equal expected, [error.code, error.retryable]
    end
    @transport.expects(:request).raises(HTTP::TimeoutError, 'secret provider error text')
    error = assert_raises(AttachmentScanner::Client::Failure) { @client.fetch(SCAN_ID) }
    assert_equal 'transport_error', error.message
    assert error.retryable
  end

  test 'response parsing is bounded and does not expose provider payloads in errors' do
    [Response.new(code: 200, headers: {}, body: ['sensitive invalid JSON']),
     Response.new(code: 200, headers: {}, body: ['x' * (64.kilobytes + 1)])].each do |received|
      @transport.expects(:request).yields(received)
      error = assert_raises(AttachmentScanner::Client::Failure) { @client.fetch(SCAN_ID) }
      assert_includes %w[invalid_response response_too_large], error.code
      assert_not_includes error.message, 'sensitive'
    end
  end

  test 'regional redirects retain the method and bytes but arbitrary destinations receive nothing' do
    io = StringIO.new('synthetic document')
    @transport.expects(:request).with(:post, 'https://us-east-1.attachmentscanner.com/v1.0/scans', anything)
              .yields(Response.new(code: 307, headers: { 'Location' => 'https://eu-west-1.attachmentscanner.com/v1.0/scans' }, body: []))
    @transport.expects(:request).with(:post, 'https://eu-west-1.attachmentscanner.com/v1.0/scans', anything).yields(response('pending'))
    assert_equal 'pending', @client.submit(io: io, filename: 'opaque-attempt.pdf', content_type: 'application/pdf').status

    ['https://attacker.example/v1.0/scans', 'http://us-east-1.attachmentscanner.com/v1.0/scans',
     'https://us-east-1.attachmentscanner.com:8443/v1.0/scans'].each do |location|
      @transport.expects(:request).once.yields(Response.new(code: 307, headers: { 'Location' => location }, body: []))
      error = assert_raises(AttachmentScanner::Client::Failure) { @client.fetch(SCAN_ID) }
      assert_equal 'unsafe_redirect', error.code
    end
  end

  test 'each redirect reserves another actual request and rechecks active work' do
    guard = mock('active scan work')
    guard.expects(:call).times(3).returns(true)
    @budget.expects(:wait_for_slot!).times(3)
    client = AttachmentScanner::Client.new(configuration: @configuration, budget: @budget, before_request: guard)
    @transport.expects(:request).with(:get, "https://us-east-1.attachmentscanner.com/v1.0/scans/#{SCAN_ID}")
              .yields(Response.new(code: 307, headers: { 'Location' => "https://eu-west-1.attachmentscanner.com/v1.0/scans/#{SCAN_ID}" }, body: []))
    @transport.expects(:request).with(:get, "https://eu-west-1.attachmentscanner.com/v1.0/scans/#{SCAN_ID}")
              .yields(Response.new(code: 308, headers: { 'Location' => "https://ap-southeast-2.attachmentscanner.com/v1.0/scans/#{SCAN_ID}" }, body: []))
    @transport.expects(:request).with(:get, "https://ap-southeast-2.attachmentscanner.com/v1.0/scans/#{SCAN_ID}").yields(response('ok'))
    assert_equal 'ok', client.fetch(SCAN_ID).status
  end

  test 'cancellation after pacing prevents the HTTP request' do
    client = AttachmentScanner::Client.new(configuration: @configuration, budget: @budget, before_request: -> { false })
    @budget.expects(:wait_for_slot!).once
    HTTP.expects(:auth).never
    error = assert_raises(AttachmentScanner::Client::Failure) { client.fetch(SCAN_ID) }
    assert_equal 'scan_canceled', error.code
    assert_not error.retryable
  end

  private

  def response(status, **fields)
    data = { id: SCAN_ID, status: status, sha256: 'a' * 64, content_length: 18 }.merge(fields)
    Response.new(code: 200, headers: {}, body: [JSON.generate(data)])
  end
end
