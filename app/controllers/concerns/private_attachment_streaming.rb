# frozen_string_literal: true

# Keeps private file responses non-cacheable, including authentication refusals and storage failures.
module PrivateAttachmentStreaming
  extend ActiveSupport::Concern
  include ActiveStorage::Streaming

  included do
    prepend_before_action :set_private_download_headers
  end

  private

  # Active Storage's stream error handlers otherwise replace no-store with no-cache.
  def expires_now
    super
    response.headers.delete('Content-Length')
    set_private_download_headers
  end

  def set_private_download_headers
    response.cache_control.replace(private: true, no_store: true)
    response.headers['Cache-Control'] = 'private, no-store, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Vary'] = 'Cookie'
  end
end
