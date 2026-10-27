# frozen_string_literal: true

# Redirect shortcuts that set a notice or an alert.
module RedirectHelper
  extend ActiveSupport::Concern

  # Redirects with a notice message
  # @param path [String, Object] The path or object to redirect to
  # @param message [String] The notice message
  def redirect_with_notice(path, message)
    redirect_to path, notice: message
  end

  # Redirects with an alert message
  # @param path [String, Object] The path or object to redirect to
  # @param message [String] The alert message
  def redirect_with_alert(path, message)
    redirect_to path, alert: message
  end
end
