# frozen_string_literal: true

# Blob and representation reads share the application's document policy.
class AttachmentDownloadsController < ApplicationController
  prepend_before_action :load_document, only: %i[show representation]
  # Register the concern last so its prepended headers also cover invalid blob lookups.
  include PrivateAttachmentStreaming

  skip_before_action :authenticate_user!, if: :public_document?
  skip_before_action :check_password_change_required, if: :public_document?
  skip_before_action :enforce_required_mfa_enrollment, if: :public_document?
  # Unsigned page controls authenticate before resolving the attachment ID.
  before_action :load_attachment, only: :attachment
  before_action :authorize_document!, only: %i[show representation attachment]
  before_action :require_cleared_document!, only: %i[show representation attachment]

  rescue_from ActiveRecord::RecordNotFound, ActiveSupport::MessageVerifier::InvalidSignature,
              ActiveStorage::FileNotFoundError, with: :unavailable
  rescue_from DocumentScan::NotCleared, with: :document_not_cleared

  def show
    stream_private_blob(@blob)
  end

  def attachment
    stream_private_blob(@blob)
  end

  def representation
    # Authorize the source before processing; derived blob URLs are not a separate permission.
    processed = @blob.representation(params[:variation_key]).processed
    send_blob_stream(processed, disposition: attachment_disposition)
  end

  private

  def unavailable
    head :not_found
  end

  def document_not_cleared
    return unavailable unless request.format.html? && request.headers['Range'].blank?

    @scan_status = DocumentScan.find_by(blob: @blob)&.status || 'not_scanned'
    I18n.with_locale(current_user&.effective_message_locale || public_request_locale) do
      render :unavailable, layout: 'secure_public', status: :not_found
    end
  end

  def load_document
    @blob = ActiveStorage::Blob.find_signed!(params[:signed_blob_id] || params[:signed_id])
    @access = AttachmentAccess.new(@blob)
  end

  def load_attachment
    @blob = ActiveStorage::Attachment.find(params.expect(:attachment_id)).blob
    @access = AttachmentAccess.new(@blob)
  end

  def public_document? = @access&.public? || false

  def authorize_document!
    head :not_found unless public_document? || @access.allowed?(current_user)
  end

  def require_cleared_document!
    DocumentScan.require_clean!(@blob)
  end
end
