# frozen_string_literal: true

module DateInputHelper
  def accessible_date_value(value)
    date = DateInputNormalizer.normalize(value)
    return value if date.blank? && value.present?
    return nil if date.blank?

    date.strftime('%m/%d/%Y')
  end

  # Value for a date-of-birth text field built from a user or a submitted-params hash. Input the
  # model rejected comes back as typed, so a re-rendered form shows it for correction instead of
  # a blank field or a different date.
  def date_of_birth_input_value(source)
    return if source.nil?
    return accessible_date_value(source[:date_of_birth]) unless source.respond_to?(:date_of_birth)

    source.try(:rejected_date_of_birth_input).presence || accessible_date_value(source.date_of_birth)
  end

  # A date-of-birth text field with the settings every one shares. Callers pass their own value,
  # id, class, required state, ARIA, and data attributes; any of them overrides a default.
  def date_of_birth_text_field(form, attribute = :date_of_birth, **)
    form.text_field attribute, date_of_birth_field_options(**)
  end

  def date_of_birth_field_options(**options)
    { placeholder: t('shared.date_of_birth.placeholder'), autocomplete: 'bday', inputmode: 'numeric' }.merge(options)
  end
end
