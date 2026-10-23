# frozen_string_literal: true

require 'uri'

class CspViolationReport
  MAX_REPORTS = 10
  DIRECTIVES = %w[base-uri child-src connect-src default-src font-src form-action frame-ancestors frame-src img-src
                  manifest-src media-src object-src script-src script-src-attr script-src-elem style-src style-src-attr
                  style-src-elem worker-src].freeze

  def self.normalize(payload)
    reports = payload.is_a?(Array) ? payload : [payload]
    return if reports.empty? || reports.size > MAX_REPORTS

    normalized = reports.filter_map { |report| new(report).normalized }
    normalized.presence
  end

  def initialize(report)
    @report = report
  end

  def normalized
    body = report_body
    return unless body.is_a?(Hash)

    directive = body['effective-directive'] || body['effectiveDirective'] || body['violated-directive']
    {
      directive: DIRECTIVES.include?(directive) ? directive : 'unknown',
      document_origin: origin(body['document-uri'] || body['documentURL']),
      blocked_origin: origin(body['blocked-uri'] || body['blockedURL']),
      source_origin: origin(body['source-file'] || body['sourceFile']),
      line: position(body['line-number'] || body['lineNumber']),
      column: position(body['column-number'] || body['columnNumber']),
      disposition: %w[report enforce].include?(body['disposition']) ? body['disposition'] : 'unknown'
    }.compact
  end

  private

  def report_body
    return unless @report.is_a?(Hash)

    @report['type'] == 'csp-violation' ? @report['body'] : @report['csp-report']
  end

  def origin(value)
    return 'unknown' unless value.is_a?(String) && value.bytesize <= 2048
    return value if %w[inline eval self].include?(value)
    return Regexp.last_match(1) if value.match(/\A(data|blob|about|javascript):/)

    uri = URI.parse(value)
    return 'unknown' unless uri.is_a?(URI::HTTP) && uri.host.present?

    port = uri.port == uri.default_port ? '' : ":#{uri.port}"
    "#{uri.scheme}://#{uri.host.downcase}#{port}"
  rescue URI::InvalidURIError
    'unknown'
  end

  def position(value)
    value if value.is_a?(Integer) && value.between?(0, 1_000_000)
  end
end
