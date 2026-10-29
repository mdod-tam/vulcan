# frozen_string_literal: true

# Masks personal audit values before storage without changing the audited record.
class AuditMetadataPrivacy
  WITHHELD = '[withheld]'
  PRESERVED_VALUES = [nil, true, false, '', WITHHELD].freeze
  NAME_FIELDS = %w[first_name last_name middle_initial full_name name admin_name guardian_name actor_name user_name target_user_name
                   applicant_name trainer_name evaluator_name constituent_name provider provider_name certifying_professional_name
                   alternate_contact_name recipient_name assigned_to_name completed_by_name].freeze
  WITHHELD_FIELDS = %w[date_of_birth physical_address_1 physical_address_2 address_line1 address_line2
                       address city zip_code postal_code notes payment_notes identity_rationale rationale
                       rejection_reason decline_reason].freeze
  SECRET_FIELDS = %w[password password_confirmation current_password password_digest secret reset_password_token
                     token raw_token access_token refresh_token otp code verification_code
                     secure_upload_url reset_url password_reset_url invitation_url
                     document_signing_audit_url document_signing_document_url].freeze
  # These device values already have encrypted audit storage and operational history readers.
  ENCRYPTED_DEVICE_FIELDS = %w[tracking_number serial_number imei normalized_imei normalized_serial_number serial_duplicate_reason].freeze

  def initialize(auditable: nil)
    @encrypted_fields = auditable&.class&.try(:encrypted_attributes).to_a.map(&:to_s)
  end

  def filter(metadata)
    metadata.to_h do |key, value|
      [key, protect(value, fields: [key.to_s])]
    end
  end

  private

  # Keep enclosing fields so old/new values and sensitive wrappers retain their policy.
  def protect(value, fields:)
    case value
    when Hash
      value.to_h { |key, entry| [key, protect(entry, fields: [key.to_s, *fields])] }
    when Array
      value.map { |entry| protect(entry, fields: fields) }
    else
      fields.reduce(value) { |projected, field| protect_value(field, projected) }
    end
  end

  def protect_value(field, value)
    return value if PRESERVED_VALUES.include?(value)
    return WITHHELD if secret?(field)
    return mask_email(value) if field == 'email' || field.end_with?('_email')
    return mask_digits(value, '***-***-') if field.match?(/(?:\A|_)(?:phone|fax)(?:_number)?\z/)
    return mask_digits(value, '***-**-') if %w[business_tax_id ssn_last4].include?(field)
    return mask_name(value) if NAME_FIELDS.include?(field)
    return WITHHELD if WITHHELD_FIELDS.include?(field)
    return WITHHELD if @encrypted_fields.include?(field) && ENCRYPTED_DEVICE_FIELDS.exclude?(field) && field != 'state'

    value
  end

  def secret?(field)
    SECRET_FIELDS.include?(field) || field.end_with?('_token', '_secret', '_password', '_password_digest', '_signed_id')
  end

  def mask_email(value)
    local, domain = value.to_s.split('@', 2)
    return WITHHELD unless local.present? && domain.present?

    host, separator, suffix = domain.rpartition('.')
    return WITHHELD unless separator.present? && host.present? && suffix.match?(/\A[a-z]{2,24}\z/i)

    "#{local.first}***@#{host.first}***.#{suffix.downcase}"
  end

  def mask_digits(value, prefix)
    digits = value.to_s.gsub(/\D/, '')
    digits.length >= 4 ? "#{prefix}#{digits.last(4)}" : WITHHELD
  end

  def mask_name(value)
    value.to_s.split.map { |part| "#{part.first}***" }.join(' ')
  end
end
