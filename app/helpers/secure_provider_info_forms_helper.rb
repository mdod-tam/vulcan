# frozen_string_literal: true

module SecureProviderInfoFormsHelper
  FIELD_LABEL_KEYS = {
    medical_provider_name: 'secure_provider_info_forms.show.provider_name',
    medical_provider_email: 'secure_provider_info_forms.show.provider_email',
    medical_provider_phone: 'secure_provider_info_forms.show.provider_phone',
    medical_provider_fax: 'secure_provider_info_forms.show.provider_fax'
  }.freeze

  def secure_provider_info_field_label(attribute)
    key = FIELD_LABEL_KEYS[attribute.to_sym]
    return '' if key.blank?

    t(key, default: '')
  end
end
