# frozen_string_literal: true

module SecureFormLocaleResolver
  # The supported locale for a secure form recipient, or the default locale.
  def self.for_recipient(recipient)
    locale = if recipient.respond_to?(:effective_message_locale)
               recipient.effective_message_locale
             elsif recipient.respond_to?(:locale)
               recipient.locale
             end
    normalize(locale)
  end

  def self.normalize(locale)
    candidate = locale.to_s.to_sym
    I18n.available_locales.include?(candidate) ? candidate : I18n.default_locale
  end

  private

  def secure_form_locale_for(recipient)
    SecureFormLocaleResolver.for_recipient(recipient)
  end
end
