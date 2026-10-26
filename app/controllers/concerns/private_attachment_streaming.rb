# frozen_string_literal: true

# Keeps private file responses non-cacheable, including authentication refusals and storage failures.
module PrivateAttachmentStreaming
  extend ActiveSupport::Concern
  include ActiveStorage::Streaming

  included do
    prepend_before_action :set_private_download_headers
  end

  private

  def stream_private_blob(blob)
    response.headers['Accept-Ranges'] = 'bytes'
    if request.headers['Range'].present?
      send_blob_byte_range_data(blob, request.headers['Range'], disposition: attachment_disposition)
    else
      response.headers['Content-Length'] = blob.byte_size.to_s
      send_blob_stream(blob, disposition: attachment_disposition)
    end
  end

  def attachment_disposition = params[:disposition] == 'attachment' ? 'attachment' : 'inline'

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
