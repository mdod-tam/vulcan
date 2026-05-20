# frozen_string_literal: true

class SecurePublicFormController < ApplicationController
  skip_before_action :authenticate_user!, raise: false
  skip_before_action :check_password_change_required, raise: false
  skip_before_action :verify_authenticity_token, raise: false

  before_action :set_secure_headers
  helper_method :support_email, :support_phone

  private

  def render_unavailable
    render :unavailable, status: :ok
  end

  def render_submitted
    render :submitted, status: :ok
  end

  def render_html_response(template_name, status: :ok)
    render template_name,
           formats: :html,
           content_type: Mime[:html].to_s,
           status: status
  end

  def set_secure_headers
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end

  def with_request_locale(&)
    I18n.with_locale(locale_from_request, &)
  end

  def locale_from_request
    recipient = locale_recipient_for_request

    recipient&.effective_locale.presence ||
      recipient&.locale.presence ||
      I18n.default_locale
  end

  def locale_recipient_for_request
    # Subclasses must set @secure_request_form before with_request_locale runs.
    @secure_request_form&.recipient
  end

  def public_constituent_name(user, fallback: '')
    return fallback if user.blank?

    first_name = user.first_name.to_s.strip
    last_initial = user.last_name.to_s.strip.first
    [first_name.presence, (last_initial.present? ? "#{last_initial}." : nil)].compact.join(' ').presence || fallback
  end

  def support_email
    Policy.get('support_email') || 'mat.program1@maryland.gov'
  end

  def support_phone
    Policy.get('support_phone') || '410-767-6960'
  end
end
