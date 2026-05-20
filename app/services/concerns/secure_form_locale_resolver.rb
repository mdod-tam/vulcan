# frozen_string_literal: true

module SecureFormLocaleResolver
  private

  def secure_form_locale_for(recipient)
    locale = if recipient.respond_to?(:effective_locale)
               recipient.effective_locale
             elsif recipient.respond_to?(:locale)
               recipient.locale
             end

    locale.presence || I18n.locale
  end
end
