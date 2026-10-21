# frozen_string_literal: true

module LocalizedContactLabelsHelper
  def localized_contact_label(group, value)
    return I18n.t('application_contact.not_provided') if value.blank?

    label = I18n.t("application_contact.#{group}.#{value}", default: nil)
    label.is_a?(String) ? label : value.to_s.humanize
  end
end
