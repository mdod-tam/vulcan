# frozen_string_literal: true

require 'test_helper'

class CspViolationReportTest < ActiveSupport::TestCase
  test 'report projection retains only bounded technical categories and origins' do
    payload = { 'csp-report' => {
      'effective-directive' => 'script-src-elem', 'document-uri' => 'https://user:secret@example.test/private?token=secret',
      'blocked-uri' => 'data:secret-payload', 'source-file' => 'https://cdn.example.test/assets/private.js',
      'line-number' => 10, 'column-number' => 'secret', 'script-sample' => 'secret',
      'disposition' => 'report', 'arbitrary' => 'secret'
    } }

    report = CspViolationReport.normalize(payload).sole

    assert_equal({ directive: 'script-src-elem', document_origin: 'https://example.test', blocked_origin: 'data',
                   source_origin: 'https://cdn.example.test', line: 10, disposition: 'report' }, report)
    assert_not_includes report.to_json, 'secret'
  end

  test 'untrusted directive and malformed URLs cannot inject log content' do
    report = CspViolationReport.normalize('csp-report' => {
                                            'effective-directive' => "secret\nforged log entry",
                                            'document-uri' => "https://example.test/\nsecret",
                                            'blocked-uri' => 'x' * 3000
                                          }).sole

    assert_equal 'unknown', report[:directive]
    assert_equal 'unknown', report[:document_origin]
    assert_equal 'unknown', report[:blocked_origin]
  end
end
