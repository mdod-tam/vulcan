# frozen_string_literal: true

require 'json'

module AttachmentScanner
  class LogSubscriber
    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def emit(event)
      payload = event.fetch(:payload).slice(:document_scan_id, :status, :error_code, :count, :owner_type)
      level = payload[:status] == 'clean' ? :info : :warn
      @logger.public_send(level, JSON.generate({ event: event.fetch(:name) }.merge(payload)))
    end
  end
end
