# frozen_string_literal: true

require 'json'

module Security
  # Validate before Rails request logging, which can otherwise print malformed JSON.
  class CspReportFilter
    PATH = %r{\A/csp_reports(?:\.[^/]+)?/?\z}
    PAYLOAD_KEY = 'mat_vulcan.csp_report_payload'
    MAX_BYTES = 16_384
    CONTENT_TYPES = %w[application/csp-report application/reports+json application/json].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      path = ActionDispatch::Journey::Router::Utils.normalize_path(env['PATH_INFO'])
      return @app.call(env) unless PATH.match?(path)

      env['action_dispatch.parameter_filter'] = Array(env['action_dispatch.parameter_filter']) + [/.*/]
      return reject(400) if env['QUERY_STRING'].present?

      request = ActionDispatch::Request.new(env)
      return reject(415) unless CONTENT_TYPES.include?(request.media_type)
      return reject(413) if request.content_length.to_i > MAX_BYTES

      body = request.body.read(MAX_BYTES + 1)
      return reject(413) if body.bytesize > MAX_BYTES

      request.body.rewind
      env[PAYLOAD_KEY] = parse(body)
      @app.call(env)
    rescue InvalidReport, ActionDispatch::Http::MimeNegotiation::InvalidType
      reject(400)
    end

    private

    class InvalidReport < StandardError; end

    def parse(body)
      JSON.parse(body, max_nesting: 20)
    rescue JSON::ParserError
      raise InvalidReport
    end

    def reject(status)
      [status, { 'content-type' => 'text/plain; charset=utf-8', 'cache-control' => 'no-store' }, []]
    end
  end
end
