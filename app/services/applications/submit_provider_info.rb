# frozen_string_literal: true

module Applications
  class SubmitProviderInfo < BaseService
    include SecureFormLocaleResolver

    MESSAGE_SCOPE = 'applications.provider_info.messages'
    PROVIDER_FIELDS = %i[
      medical_provider_name
      medical_provider_email
      medical_provider_phone
      medical_provider_fax
    ].freeze
    PHONE_NUMBER_PATTERN = /\A(?:\d{10}|\d{3}-\d{3}-\d{4})\z/
    PHONE_NUMBER_FIELDS = %i[medical_provider_phone medical_provider_fax].freeze

    attr_reader :application, :secure_request_form, :params, :form_errors

    delegate :model_name, to: :class

    def self.human_attribute_name(attribute, *_args)
      attribute.to_s.humanize
    end

    def self.lookup_ancestors
      [self]
    end

    def self.model_name
      ActiveModel::Name.new(self, nil, 'ProviderInfo')
    end

    def initialize(application:, secure_request_form:, params:)
      super()
      @application = application
      @secure_request_form = secure_request_form
      @params = params.to_h.symbolize_keys.slice(*PROVIDER_FIELDS)
    end

    def call
      return invalid_request_failure unless provider_info_request_form?
      return invalid_request_failure unless secure_request_form.application_id == application.id
      return inactive_request_failure unless secure_request_form.active_for_public_use?
      return validation_failure unless provider_params_valid?

      result = nil

      ApplicationRecord.transaction do
        secure_request_form.with_lock do
          secure_request_form.reload
          unless provider_info_request_form?
            result = invalid_request_failure
            next
          end

          unless secure_request_form.active_for_public_use?
            result = inactive_request_failure
            next
          end

          previous_presence = field_presence(application.attributes.symbolize_keys)

          application.update!(normalized_provider_params)
          secure_request_form.mark_submitted!
          log_submission(previous_presence)
          result = success(message(:submitted))
        end
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { errors: e.record.errors })
    end

    def read_attribute_for_validation(attribute)
      params[attribute]
    end

    private

    def provider_info_request_form?
      secure_request_form&.kind_provider_info_request?
    end

    def invalid_request_failure
      failure(message(:invalid_request))
    end

    def inactive_request_failure
      key = if secure_request_form.submitted?
              :already_submitted
            elsif secure_request_form.revoked?
              :revoked
            elsif secure_request_form.expired?
              :expired
            else
              :invalid_request
            end

      failure(message(key))
    end

    def provider_params_valid?
      @form_errors = ActiveModel::Errors.new(self)
      validate_presence(:medical_provider_name)
      validate_presence(:medical_provider_phone)
      validate_presence(:medical_provider_email)
      validate_email
      validate_phone_number(:medical_provider_phone)
      validate_phone_number(:medical_provider_fax)
      form_errors.blank?
    end

    def validation_failure
      failure(message(:validation_failed), { errors: form_errors })
    end

    def validate_presence(attribute)
      form_errors.add(attribute, :blank, message: message(:"#{attribute}_blank")) if params[attribute].blank?
    end

    def validate_email
      return if params[:medical_provider_email].blank?
      return if params[:medical_provider_email].match?(URI::MailTo::EMAIL_REGEXP)

      form_errors.add(:medical_provider_email, :invalid, message: message(:medical_provider_email_invalid))
    end

    def validate_phone_number(attribute)
      value = params[attribute]
      return if value.blank?
      return if value.match?(PHONE_NUMBER_PATTERN)

      form_errors.add(attribute, :invalid, message: message(:"#{attribute}_invalid"))
    end

    def normalized_provider_params
      params.merge(
        PHONE_NUMBER_FIELDS.index_with do |field|
          normalize_phone_number(params[field])
        end
      )
    end

    def normalize_phone_number(value)
      return value if value.blank?

      value.delete('-').gsub(/(\d{3})(\d{3})(\d{4})/, '\1-\2-\3')
    end

    def log_submission(previous_presence)
      AuditEventService.log(
        action: 'medical_provider_info_submitted',
        actor: secure_request_form.recipient,
        auditable: application,
        metadata: {
          submitted_via: 'secure_request_form',
          secure_request_form_id: secure_request_form.id,
          recipient_user_id: secure_request_form.recipient_id,
          recipient_role: secure_request_form.recipient_role,
          recipient_relationship_type: secure_request_form.recipient_relationship_type,
          request_batch_id: secure_request_form.request_batch_id,
          changed_fields: changed_provider_fields,
          previous_presence: previous_presence,
          submitted_presence: field_presence(params)
        }
      )
    end

    def changed_provider_fields
      PROVIDER_FIELDS.select { |field| application.saved_change_to_attribute?(field) }.map(&:to_s)
    end

    def field_presence(values)
      PROVIDER_FIELDS.index_with { |field| values[field].present? }
    end

    def message(key)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", locale: secure_form_locale_for(secure_request_form.recipient))
    end
  end
end
