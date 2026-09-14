# frozen_string_literal: true

module SecureFormLocaleResolver
  private

  def secure_form_locale_for(recipient)
    locale = if recipient.respond_to?(:effective_message_locale)
               recipient.effective_message_locale
             elsif recipient.respond_to?(:locale)
               recipient.locale
             end
    candidate = locale.to_s.to_sym
    I18n.available_locales.include?(candidate) ? candidate : I18n.default_locale
  end
end
