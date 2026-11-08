# frozen_string_literal: true

module RegistrationTestHelper
  # A real signed proof fixture for tests whose subject is the subsequent form or cookie.
  def registration_completion_path(email: "verified-#{SecureRandom.hex(6)}@example.test", locale: 'en')
    verification = RegistrationVerification.create!(email: email, locale: locale, expires_at: 20.minutes.from_now)
    edit_registration_verification_path(token: verification.proof_token)
  end

  def submit_verified_registration(attributes)
    verification = RegistrationVerification.create!(email: attributes.fetch(:email), locale: attributes.fetch(:locale, 'en'),
                                                    expires_at: 20.minutes.from_now)
    patch registration_verification_path(token: verification.proof_token), params: { user: attributes }
  end
end

ActiveSupport.on_load(:active_support_test_case) { include RegistrationTestHelper }
