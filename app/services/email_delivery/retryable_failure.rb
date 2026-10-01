# frozen_string_literal: true

module EmailDelivery
  # Retry only when the provider could not accept the envelope. A timeout or HTTP 500 is uncertain.
  class RetryableFailure < StandardError
    def self.transient?(error)
      (error.is_a?(Postmark::HttpServerError) && [429, 503].include?(error.status_code)) ||
        error.is_a?(SocketError) || error.is_a?(Errno::ECONNREFUSED)
    end

    def self.rejected?(error)
      transient?(error) || (error.is_a?(Postmark::HttpServerError) && [401, 404, 413, 415, 422].include?(error.status_code))
    end
  end
end
