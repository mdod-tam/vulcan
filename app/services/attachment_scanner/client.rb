# frozen_string_literal: true

require 'http'
require 'json'
require 'uri'

module AttachmentScanner
  class Client
    Result = Data.define(:status, :scan_id, :sha256, :byte_size)
    STATUSES = %w[ok found warning pending failed].freeze
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    MAX_RESPONSE_BYTES = 64.kilobytes

    class Failure < StandardError
      attr_reader :code, :retryable

      def initialize(code, retryable: false)
        @code = code.to_s
        @retryable = retryable
        super(@code)
      end
    end

    def initialize(configuration: Rails.application.config.x.attachment_scanner, budget: DocumentScanProviderBudget, before_request: nil)
      raise Failure, :not_configured unless configuration.configured?

      @configuration = configuration
      @budget = budget
      @before_request = before_request
    end

    def submit(io:, filename:, content_type:)
      file = HTTP::FormData::File.new(io, filename: filename, content_type: content_type)
      request(:post, '/v1.0/scans', form: { file: file, async: 'true' })
    end

    def fetch(scan_id)
      raise Failure, :invalid_scan_id unless scan_id.is_a?(String) && scan_id.match?(UUID)

      request(:get, "/v1.0/scans/#{scan_id}")
    end

    private

    def request(method, path, form: nil)
      url = "#{@configuration.url.delete_suffix('/')}#{path}"
      3.times do |redirects|
        @budget.wait_for_slot!
        raise Failure, :scan_canceled if @before_request && !@before_request.call

        result = nil
        HTTP.auth("Bearer #{@configuration.token}").timeout(connect: 5, write: 30, read: 35, global: 45)
            .request(method, url, **(form ? { form: form } : {})) do |received|
          if [307, 308].include?(received.code)
            raise Failure, :too_many_redirects if redirects == 2

            url = redirect_url(received, url)
            form&.fetch(:file)&.rewind
          else
            result = parse_response(received)
          end
        end
        return result if result
      end
    rescue HTTP::Error, IOError, SystemCallError
      raise Failure.new(:transport_error, retryable: true)
    end

    def redirect_url(response, current)
      target = URI.join(current, response.headers['Location'].to_s)
      origin = "#{target.scheme}://#{target.host}:#{target.port}"
      unless Configuration.trusted_origin?(origin) && target.userinfo.nil? && target.query.nil? && target.fragment.nil? &&
             target.path == URI.parse(current).path
        raise Failure, :unsafe_redirect
      end

      target.to_s
    rescue URI::InvalidURIError
      raise Failure, :unsafe_redirect
    end

    def parse_response(response)
      unless response.code == 200
        code = { 401 => :unauthorized, 402 => :subscription_expired, 404 => :scan_missing, 422 => :request_rejected, 429 => :rate_limited }[response.code]
        raise Failure.new(code || :provider_error, retryable: response.code == 429 || response.code >= 500)
      end

      body = +''
      response.body.each do |chunk|
        raise Failure, :response_too_large if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

        body << chunk
      end
      normalize(JSON.parse(body))
    rescue JSON::ParserError, EncodingError
      raise Failure, :invalid_response
    end

    def normalize(data)
      raise Failure, :invalid_response unless data.is_a?(Hash) && data['id'].is_a?(String) && data['id'].match?(UUID) && STATUSES.include?(data['status'])

      sha256 = data['sha256']
      byte_size = data['content_length']
      raise Failure, :invalid_response unless valid_fingerprint?(sha256, byte_size, required: data['status'] == 'ok')

      Result.new(status: data['status'], scan_id: data['id'].downcase, sha256: sha256&.downcase, byte_size: byte_size)
    end

    def valid_fingerprint?(sha256, byte_size, required:)
      return !required if sha256.nil? && byte_size.nil?

      sha256.is_a?(String) && sha256.match?(/\A[0-9a-f]{64}\z/i) && byte_size.is_a?(Integer) && byte_size >= 0
    end
  end
end
