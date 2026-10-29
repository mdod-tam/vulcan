# frozen_string_literal: true

module SecureProviderInfoFormsHelper
  FIELD_LABEL_KEYS = {
    certifying_professional_name: 'secure_provider_info_forms.show.provider_name',
    certifying_professional_email: 'secure_provider_info_forms.show.provider_email',
    certifying_professional_phone: 'secure_provider_info_forms.show.provider_phone',
    certifying_professional_fax: 'secure_provider_info_forms.show.provider_fax'
  }.freeze

  def secure_provider_info_field_label(attribute)
    key = FIELD_LABEL_KEYS[attribute.to_sym]
    return '' if key.blank?

    t(key, default: '')
  end
end
