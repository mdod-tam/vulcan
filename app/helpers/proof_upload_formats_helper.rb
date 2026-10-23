# frozen_string_literal: true

module ProofUploadFormatsHelper
  def proof_upload_accept_attribute
    ProofUploadFormats::ACCEPT_ATTRIBUTE
  end

  def proof_upload_formats_label
    ProofUploadFormats::HUMAN_LABEL
  end

  def proof_upload_max_size_label
    "#{ProofUploadFormats.max_megabytes(:proof)}MB"
  end

  # Data attributes for shared/_document_upload. Limits and refusal wording come from the purpose the
  # model declares for the slot, the same ones UploadedDocument enforces.
  def document_upload_data(model, field, purpose: nil, slot: field, secure_form_type: nil)
    purpose ||= UploadedDocument.declared_purpose(model, field)
    {
      controller: 'document-upload',
      action: 'document-upload:clear->document-upload#remove',
      document_upload_allowed_types_value: ProofUploadFormats.allowed_content_types_json(purpose),
      document_upload_max_bytes_value: ProofUploadFormats.max_bytes(purpose),
      document_upload_max_inclusive_value: ProofUploadFormats.max_inclusive?(purpose),
      document_upload_invalid_type_message_value: UploadedDocument.refusal_message(:invalid_type, purpose: purpose),
      document_upload_too_large_message_value: UploadedDocument.refusal_message(:too_large, purpose: purpose),
      document_upload_uploading_text_value: t('documents.upload.uploading'),
      document_upload_uploaded_text_value: t('documents.upload.uploaded'),
      document_upload_canceled_text_value: t('documents.upload.canceled'),
      document_upload_failed_text_value: t('documents.upload.failed'),
      document_upload_scanning_text_value: t('documents.upload.scanning'),
      document_upload_blocked_text_value: t('documents.upload.blocked'),
      document_upload_unavailable_text_value: t('documents.upload.unavailable'),
      document_upload_wait_text_value: t('documents.upload.wait'),
      document_upload_link_unavailable_text_value: t('documents.scan.link_unavailable'),
      document_upload_session_expired_text_value: t('documents.upload.session_expired'),
      document_upload_scans_url_value: document_scans_path,
      document_upload_purpose_value: purpose,
      document_upload_slot_value: slot,
      document_upload_context_value: document_scan_context(model),
      document_upload_persist_context_value: document_scan_new_context?(model),
      document_upload_secure_form_type_value: secure_form_type,
      document_upload_token_value: (params[:token] if secure_form_type)
    }
  end

  def document_scan_context(model)
    if document_scan_new_context?(model)
      @document_scan_context ||= params[:document_scan_context].to_s.match?(/\A[0-9a-f-]{36}\z/i) ? params[:document_scan_context] : SecureRandom.uuid
    elsif controller_path == 'constituent_portal/applications'
      "application:#{model.user_id || current_user.id}:#{model.application_date&.year || Date.current.year}"
    else
      "#{controller_path}:#{(model.respond_to?(:id) && model.id) || params[:application_id] || 'new'}"
    end
  end

  def document_scan_new_context?(model)
    controller_path == 'admin/paper_applications' ||
      (controller_path == 'admin/product_resources' && !model.persisted?)
  end
end
