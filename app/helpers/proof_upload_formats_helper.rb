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
  def document_upload_data(model, field)
    purpose = UploadedDocument.declared_purpose(model, field)
    {
      controller: 'document-upload',
      action: 'document-upload:clear->document-upload#remove',
      document_upload_allowed_types_value: ProofUploadFormats.allowed_content_types_json,
      document_upload_max_bytes_value: ProofUploadFormats.max_bytes(purpose),
      document_upload_max_inclusive_value: ProofUploadFormats.max_inclusive?(purpose),
      document_upload_invalid_type_message_value: UploadedDocument.refusal_message(:invalid_type, purpose: purpose),
      document_upload_too_large_message_value: UploadedDocument.refusal_message(:too_large, purpose: purpose),
      document_upload_selected_text_value: t('documents.upload.selected'),
      document_upload_uploading_text_value: t('documents.upload.uploading'),
      document_upload_uploaded_text_value: t('documents.upload.uploaded'),
      document_upload_canceled_text_value: t('documents.upload.canceled'),
      document_upload_failed_text_value: t('documents.upload.failed')
    }
  end
end
