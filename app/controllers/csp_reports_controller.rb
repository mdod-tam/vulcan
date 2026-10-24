# frozen_string_literal: true

# Browser diagnostics have no application authentication callbacks or account/audit side effects.
class CspReportsController < ActionController::Base # rubocop:disable Rails/ApplicationController -- Public diagnostics must not run account callbacks.
  skip_forgery_protection

  before_action -> { response.headers['Cache-Control'] = 'no-store' }

  rate_limit to: 30, within: 1.minute,
             by: -> { AuthRateLimit.request_ip_digest(request) },
             with: -> { head :too_many_requests }

  def create
    reports = CspViolationReport.normalize(request.get_header(Security::CspReportFilter::PAYLOAD_KEY))
    return head :bad_request unless reports

    reports.each { |report| Rails.logger.warn("CSP violation: #{report.to_json}") }
    head :no_content
  end
end
