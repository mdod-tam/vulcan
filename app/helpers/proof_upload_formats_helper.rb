# frozen_string_literal: true

module ProofUploadFormatsHelper
  def proof_upload_accept_attribute
    ProofUploadFormats::ACCEPT_ATTRIBUTE
  end

  def proof_upload_formats_label
    ProofUploadFormats::HUMAN_LABEL
  end

  def proof_upload_stimulus_values
    {
      upload_allowed_types_value: ProofUploadFormats.allowed_content_types_json,
      upload_invalid_type_message_value: ProofUploadFormats::INVALID_TYPE_MESSAGE,
      upload_max_file_size_value: ActiveStorageValidatable::MAX_FILE_SIZE
    }
  end
end
