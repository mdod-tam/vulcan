# frozen_string_literal: true

module ViewerLocale
  extend ActiveSupport::Concern

  private

  def with_viewer_locale(&)
    requested = params[:locale].to_s.to_sym
    locale = I18n.available_locales.include?(requested) ? requested : current_user&.effective_message_locale
    I18n.with_locale(locale || I18n.default_locale, &)
  end
end
