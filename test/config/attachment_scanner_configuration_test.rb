# frozen_string_literal: true

require 'bundler/setup'
require 'active_support/test_case'
require 'minitest/autorun'
require_relative '../../app/services/attachment_scanner/configuration'

class AttachmentScannerConfigurationTest < ActiveSupport::TestCase
  test 'persistent runtime requires complete credentials while absent optional configuration stays unavailable' do
    assert_raises(AttachmentScanner::Configuration::Invalid) { AttachmentScanner::Configuration.load(env: {}, required: true) }
    assert_not AttachmentScanner::Configuration.load(env: {}, required: false).configured?
    assert_raises(AttachmentScanner::Configuration::Invalid) do
      AttachmentScanner::Configuration.load(env: { 'ATTACHMENT_SCANNER_URL' => 'https://us-east-1.attachmentscanner.com' }, required: false)
    end
  end

  test 'only a provider HTTPS origin can receive the API token and document bytes' do
    %w[https://us-east-1.attachmentscanner.com https://clustername.attachmentscanner.com/].each do |url|
      assert AttachmentScanner::Configuration.new(url: url, token: 'synthetic-token').configured?
    end
    %w[http://us-east-1.attachmentscanner.com https://attacker.example https://attachmentscanner.com.attacker.example
       https://us-east-1.attachmentscanner.com:8443 https://us-east-1.attachmentscanner.com/path
       https://us-east-1.attachmentscanner.com?secret=yes https://user:secret@us-east-1.attachmentscanner.com].each do |url|
      error = assert_raises(AttachmentScanner::Configuration::Invalid) do
        AttachmentScanner::Configuration.new(url: url, token: 'sensitive-token')
      end
      assert_equal 'Invalid or missing ATTACHMENT_SCANNER_URL', error.message
      assert_not_includes error.message, 'sensitive'
    end
  end

  test 'blank or header-breaking credentials fail without disclosing them' do
    [nil, '', ' ', "secret\nvalue"].each do |token|
      error = assert_raises(AttachmentScanner::Configuration::Invalid) do
        AttachmentScanner::Configuration.new(url: 'https://us-east-1.attachmentscanner.com', token: token)
      end
      assert_equal 'Invalid or missing ATTACHMENT_SCANNER_API_TOKEN', error.message
    end
  end
end
