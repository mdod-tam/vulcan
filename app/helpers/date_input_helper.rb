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
    typed_date_input_value(source, :date_of_birth)
  end

  # The same for any TypedDateInput attribute.
  def typed_date_input_value(source, attribute)
    return if source.nil?
    return accessible_date_value(source[attribute]) unless source.respond_to?(attribute)

    source.try(:"rejected_#{attribute}_input").presence || accessible_date_value(source.public_send(attribute))
  end

  # A date-of-birth text field with the settings every one shares. Callers pass their own value,
  # id, class, required state, ARIA, and data attributes; any of them overrides a default.
  def date_of_birth_text_field(form, attribute = :date_of_birth, **)
    form.text_field attribute, date_of_birth_field_options(**)
  end

  def date_of_birth_field_options(**)
    typed_date_field_options(autocomplete: 'bday', **)
  end

  # Settings every typed-date text field shares; callers' options override them.
  def typed_date_field_options(**options)
    { placeholder: t('shared.date_of_birth.placeholder'), inputmode: 'numeric' }.merge(options)
  end
end
