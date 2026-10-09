# frozen_string_literal: true

module Vendors
  class SubmitW9Resubmission < BaseService
    include SecureFormSubmission

    MESSAGE_SCOPE = 'vendors.w9_resubmission.messages'

    attr_reader :vendor, :vendor_secure_request_form, :file

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
      return inactive_request_failure unless vendor_secure_request_form.active_for_public_use? && vendor.w9_requestable_via_secure_form?
      return invalid_request_failure unless vendor_secure_request_form.kind_w9_upload?

      result = nil

      ApplicationRecord.transaction do
        vendor.lock!
        vendor_secure_request_form.with_lock do
          vendor_secure_request_form.reload
          unless vendor_secure_request_form.active_for_public_use? && vendor.w9_requestable_via_secure_form?
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
    rescue UploadedDocument::Refused => e
      refused_upload_failure(e)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { errors: e.record.errors })
    end

    private

    def form_belongs_to_vendor?
      vendor_secure_request_form.vendor_id == vendor.id
    end

    def request_form = vendor_secure_request_form

    # A failed attach rolls back the transaction, so the request is never consumed without a file
    def attach_w9!
      Vendors::ReplaceW9.call(vendor: vendor, file: file, signed_ids: false,
                              min_bytes: ProofUploadFormats::SECURE_FORM_MIN_BYTES)
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
