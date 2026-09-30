# frozen_string_literal: true

module Webhooks
  class EmailEventsParameterFilter
    PATH = %r{\A/webhooks/email_events(?:\.[^/]+)?/?\z}

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless PATH.match?(env['PATH_INFO'])

      # Postmark payloads can include message bodies and diagnostics under arbitrary keys.
      env['action_dispatch.parameter_filter'] = Array(env['action_dispatch.parameter_filter']) + [/.*/]
      return [400, { 'content-type' => 'text/plain; charset=utf-8' }, ['Bad Request']] unless valid_json?(env)

      @app.call(env)
    end

    private

    def valid_json?(env)
      request = ActionDispatch::Request.new(env)
      return true unless request.content_mime_type == Mime[:json] && request.content_length.positive?

      # Rails logs malformed JSON bodies and parser exception text before filtering can apply.
      ActiveSupport::JSON.decode(request.raw_post)
      true
    rescue ActiveSupport::JSON.parse_error, ActionDispatch::Http::MimeNegotiation::InvalidType
      false
    end
  end
end
