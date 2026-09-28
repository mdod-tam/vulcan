# frozen_string_literal: true

# Owns secure link timing and public URLs for every secure form type, so
# issuance, delivery copy, and admin views state the same values.
module SecureFormPolicy
  DEFAULT_LINK_EXPIRATION_HOURS = 48
  DEFAULT_RESEND_COOLDOWN_HOURS = 1

  module_function

  def link_expiration_hours
    Policy.get('secure_form_link_expiration_hours') || DEFAULT_LINK_EXPIRATION_HOURS
  end

  def resend_cooldown_hours
    Policy.get('secure_form_resend_cooldown_hours') || DEFAULT_RESEND_COOLDOWN_HOURS
  end

  def expires_at(from: Time.current)
    from + link_expiration_hours.hours
  end

  # route_name is a public secure form URL helper, such as :secure_proof_form_url.
  def public_url(route_name, raw_token)
    Rails.application.routes.url_helpers.public_send(route_name, token: raw_token, **CanonicalPublicUrlOptions.call)
  end
end
