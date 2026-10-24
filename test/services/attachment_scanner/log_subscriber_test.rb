# frozen_string_literal: true

require 'bundler/setup'
require 'active_support/test_case'
require 'active_support/core_ext/hash/slice'
require 'minitest/autorun'
require 'stringio'
require 'logger'
require_relative '../../../app/services/attachment_scanner/log_subscriber'

class AttachmentScannerLogSubscriberTest < ActiveSupport::TestCase
  test 'operational logs contain scan state without filenames tokens or document context' do
    output = StringIO.new
    subscriber = AttachmentScanner::LogSubscriber.new(logger: Logger.new(output))
    payload = { document_scan_id: 123, status: 'failed', error_code: 'unauthorized', filename: 'private-medical-name.pdf', token: 'secret-token' }
    subscriber.emit(name: 'document_scan.completed', payload: payload,
                    context: { url: 'https://private.example/secret' })
    assert_includes output.string, 'WARN'
    assert_includes output.string, 'document_scan.completed'
    assert_includes output.string, 'unauthorized'
    assert_not_includes output.string, 'private'
    assert_not_includes output.string, 'secret'
  end
end
