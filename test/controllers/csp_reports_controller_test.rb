# frozen_string_literal: true

require 'test_helper'

class CspReportsControllerTest < ActionDispatch::IntegrationTest
  test 'legacy reports are redacted before request logging and have no account side effects' do
    filtered_parameters = nil
    subscriber = lambda do |_name, _start, _finish, _id, data|
      filtered_parameters = data[:params] if data[:controller] == 'CspReportsController'
    end
    Rails.logger.expects(:warn).with do |message|
      assert_includes message, 'script-src-elem'
      assert_includes message, 'https://example.test'
      assert_not_includes message, 'SensitiveReportSentinel'
      assert_not_includes message, 'private@example.test'
      true
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'start_processing.action_controller') do
      assert_no_difference %w[User.count Session.count Event.count] do
        post csp_reports_path, params: legacy_report.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
      end
    end

    assert_response :no_content
    assert_nil response.headers['Set-Cookie']
    assert_not_includes filtered_parameters.inspect, 'SensitiveReportSentinel'
  end

  test 'modern reporting API batches are accepted' do
    payload = [{ type: 'csp-violation', body: { effectiveDirective: 'connect-src',
                                                documentURL: 'https://example.test/private?token=hidden',
                                                blockedURL: 'https://bucket.example.test/file?signature=hidden' } }]
    Rails.logger.expects(:warn).with do |message|
      assert_includes message, 'connect-src'
      assert_not_includes message, 'hidden'
      true
    end

    post csp_reports_path, params: payload.to_json, headers: { 'CONTENT_TYPE' => 'application/reports+json' }

    assert_response :no_content
  end

  test 'malformed and oversized payloads are rejected before controller processing' do
    Rails.logger.expects(:warn).never
    post csp_reports_path, params: '{"SensitiveReportSentinel":', headers: { 'CONTENT_TYPE' => 'application/json' }
    assert_response :bad_request

    post csp_reports_path, params: 'x' * (Security::CspReportFilter::MAX_BYTES + 1),
                           headers: { 'CONTENT_TYPE' => 'application/csp-report' }
    assert_response :content_too_large
  end

  test 'unsupported suffixes are still bounded and filtered before the request logger' do
    Rails.logger.expects(:warn).never
    post '/csp_reports.txt', params: '{"SensitiveReportSentinel":', headers: { 'CONTENT_TYPE' => 'application/json' }
    assert_response :bad_request

    post '/csp_reports.xml', params: 'x' * (Security::CspReportFilter::MAX_BYTES + 1),
                             headers: { 'CONTENT_TYPE' => 'application/json' }
    assert_response :content_too_large
  end

  test 'router-equivalent duplicate slashes cannot bypass pre-logger bounds' do
    Rails.logger.expects(:warn).never
    post '/csp_reports//', params: '{"SensitiveReportSentinel":', headers: { 'CONTENT_TYPE' => 'application/json' }
    assert_response :bad_request

    post '/csp_reports//', params: 'x' * (Security::CspReportFilter::MAX_BYTES + 1),
                           headers: { 'CONTENT_TYPE' => 'application/json' }
    assert_response :content_too_large
  end

  test 'arbitrary payloads and excessive batches do not create diagnostic log rows' do
    Rails.logger.expects(:warn).never
    post csp_reports_path, params: { arbitrary: 'SensitiveReportSentinel' }.to_json,
                           headers: { 'CONTENT_TYPE' => 'application/csp-report' }
    assert_response :bad_request

    post csp_reports_path, params: Array.new(11) { legacy_report }.to_json,
                           headers: { 'CONTENT_TYPE' => 'application/reports+json' }
    assert_response :bad_request
  end

  test 'a client cannot turn the collector into an unlimited log writer' do
    Rails.logger.stubs(:warn)
    CspReportsController.cache_store.expects(:increment)
                        .with(regexp_matches(/\Arate-limit:csp_reports:[a-f0-9]{64}\z/), 1, expires_in: 1.minute)
                        .times(31).returns(*(1..31).to_a)
    30.times do
      post csp_reports_path, params: legacy_report.to_json, headers: { 'CONTENT_TYPE' => 'application/csp-report' }
      assert_response :no_content
    end

    post csp_reports_path, params: legacy_report.to_json, headers: { 'CONTENT_TYPE' => 'application/csp-report' }
    assert_response :too_many_requests
  end

  test 'browser pages enforce the policy and have fresh matching nonces' do
    get sign_in_path
    assert_response :success
    policy = response.headers.fetch('Content-Security-Policy')
    assert_nil response.headers['Content-Security-Policy-Report-Only']
    nonce = css_select('meta[name="csp-nonce"]').first['content']
    assert_includes policy, "'nonce-#{nonce}'"
    assert_includes policy, "object-src 'none'"
    assert_includes policy, 'report-uri /csp_reports'
    assert_not_includes policy, "'unsafe-inline'"
    css_select('style').each { |style| assert_equal nonce, style['nonce'] }

    get sign_in_path
    assert_not_equal nonce, css_select('meta[name="csp-nonce"]').first['content']
  end

  private

  def legacy_report
    { 'csp-report' => {
      'effective-directive' => 'script-src-elem',
      'document-uri' => 'https://example.test/private/SensitiveReportSentinel?token=SensitiveReportSentinel',
      'source-file' => 'https://private@example.test/assets/SensitiveReportSentinel.js',
      'blocked-uri' => 'inline', 'script-sample' => 'SensitiveReportSentinel', 'disposition' => 'report'
    } }
  end
end
