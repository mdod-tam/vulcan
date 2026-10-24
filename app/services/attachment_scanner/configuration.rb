# frozen_string_literal: true

require 'uri'

module AttachmentScanner
  class Configuration
    class Invalid < StandardError; end

    attr_reader :url, :token

    def self.load(env: ENV, required: Rails.env.production?)
      new(url: env['ATTACHMENT_SCANNER_URL'], token: env['ATTACHMENT_SCANNER_API_TOKEN'], required: required)
    end

    def initialize(url:, token:, required: true)
      @url = url
      @token = token
      return if !required && url.nil? && token.nil?

      raise Invalid, 'Invalid or missing ATTACHMENT_SCANNER_URL' unless self.class.trusted_origin?(url)
      return if token.is_a?(String) && !token.empty? && !token.match?(/[\x00-\x20\x7f]/)

      raise Invalid, 'Invalid or missing ATTACHMENT_SCANNER_API_TOKEN'
    end

    def configured?
      !url.nil? && !token.nil?
    end

    def self.trusted_origin?(value)
      return false unless value.is_a?(String)

      uri = URI.parse(value)
      uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
        ['', '/'].include?(uri.path) && uri.host&.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.attachmentscanner\.com\z/)
    rescue URI::InvalidURIError
      false
    end
  end
end
