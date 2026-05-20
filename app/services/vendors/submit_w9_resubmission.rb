# frozen_string_literal: true

module Vendors
  class SubmitW9Resubmission < BaseService
    MESSAGE_SCOPE = 'vendors.w9_resubmission.messages'
    MAX_FILE_SIZE = 10.megabytes
    ALLOWED_CONTENT_TYPES = ['application/pdf'].freeze

    attr_reader :vendor, :vendor_secure_request_form, :file, :form_errors

    delegate :model_name, to: :class

    def self.human_attribute_name(attribute, *_args)
      attribute.to_s.humanize
    end

    def self.lookup_ancestors
      [self]
    end

    def self.model_name
      ActiveModel::Name.new(self, nil, 'W9Resubmission')
    end

    def initialize(vendor:, vendor_secure_request_form:, file:)
      super()
      @vendor = vendor
      @vendor_secure_request_form = vendor_secure_request_form
      @file = file
    end

    def call
      return invalid_request_failure unless form_belongs_to_vendor?
      return inactive_request_failure unless vendor_secure_request_form.active_for_public_use?
      return invalid_request_failure unless vendor_secure_request_form.kind_w9_upload?
      return validation_failure unless file_valid?

      result = nil

      ApplicationRecord.transaction do
        vendor_secure_request_form.with_lock do
          vendor_secure_request_form.reload
          unless vendor_secure_request_form.active_for_public_use?
            result = inactive_request_failure
            next
          end

          attach_w9!
          vendor_secure_request_form.mark_submitted!
          log_submission
          result = success(message(:submitted))
        end
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { errors: e.record.errors })
    end

    def read_attribute_for_validation(attribute)
      public_send(attribute)
    end

    private

    def form_belongs_to_vendor?
      vendor_secure_request_form.vendor_id == vendor.id
    end

    def invalid_request_failure
      failure(message(:invalid_request))
    end

    def inactive_request_failure
      key = if vendor_secure_request_form.submitted?
              :already_submitted
            elsif vendor_secure_request_form.revoked?
              :revoked
            elsif vendor_secure_request_form.expired?
              :expired
            else
              :invalid_request
            end

      failure(message(key))
    end

    def validation_failure
      failure(message(:validation_failed), { errors: form_errors })
    end

    def file_valid?
      @form_errors = ActiveModel::Errors.new(self)
      validate_file
      form_errors.blank?
    end

    def validate_file
      if file.blank?
        form_errors.add(:file, :blank, message: message(:file_blank))
        return
      end

      if detected_content_type != 'application/pdf'
        form_errors.add(:file, :invalid, message: message(:file_type_invalid))
        return
      end

      return unless file_size_bytes > MAX_FILE_SIZE

      form_errors.add(:file, :too_large, message: message(:file_too_large, max_size: MAX_FILE_SIZE / 1.megabyte))
    end

    def detected_content_type
      @detected_content_type ||= begin
        io = upload_io
        content_type = Marcel::MimeType.for(io, name: original_filename)
        io.rewind if io.respond_to?(:rewind)
        content_type
      end
    end

    def file_size_bytes
      file.respond_to?(:size) ? file.size.to_i : upload_io.size.to_i
    end

    def upload_io
      @upload_io ||= if file.respond_to?(:tempfile)
                       file.tempfile
                     else
                       file
                     end
    end

    def original_filename
      if file.respond_to?(:original_filename)
        file.original_filename
      elsif file.respond_to?(:path)
        File.basename(file.path)
      else
        'w9.pdf'
      end
    end

    def attach_w9!
      vendor.w9_form.attach(file)
    end

    def log_submission
      AuditEventService.log(
        action: 'w9_submitted_via_secure_form',
        actor: vendor,
        auditable: vendor,
        metadata: {
          vendor_secure_request_form_id: vendor_secure_request_form.id,
          vendor_id: vendor.id,
          request_batch_id: vendor_secure_request_form.request_batch_id
        }
      )
    end

    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: vendor.effective_locale.presence || vendor.locale.presence || I18n.locale)
    end
  end
end
