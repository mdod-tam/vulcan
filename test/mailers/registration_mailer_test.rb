# frozen_string_literal: true

require 'test_helper'

class RegistrationMailerTest < ActionMailer::TestCase
  setup do
    load_seeded_email_templates('registration_email_verification')
  end

  test 'proof mail uses the request destination locale and original deadline without queueing a bearer' do
    freeze_time do
      verification = RegistrationVerification.create!(email: 'correo@example.test', locale: 'es', expires_at: 20.minutes.from_now)
      travel 10.minutes
      mail = RegistrationMailer.with(registration_verification: verification).email_verification.message
      assert_equal ['correo@example.test'], mail.to
      assert_equal 'Confirme su correo electrónico para continuar con MAT', mail.subject
      assert_includes mail.body.to_s, I18n.l(verification.expires_at, format: :long, locale: :es)
      assert_includes mail.body.to_s, verification.expires_at.zone
      url = URI.parse(mail.body.to_s[%r{https?://\S+}])
      token = URI.decode_www_form(url.query).to_h.fetch('token')
      assert_equal verification, RegistrationVerification.resolve(token)
      assert_not_includes Base64.urlsafe_decode64(token.split('--').first), verification.email

      travel 11.minutes
      assert_nil RegistrationVerification.resolve(token)
    end
  end

  test 'delayed mail cannot revive an expired request or send a consumed link' do
    expired = RegistrationVerification.create!(email: 'expired@example.test', locale: 'en', expires_at: 1.minute.ago)
    consumed = RegistrationVerification.create!(email: 'consumed@example.test', locale: 'en',
                                                expires_at: 20.minutes.from_now, consumed_at: Time.current)
    [expired, consumed].each do |verification|
      assert_no_difference('ActionMailer::Base.deliveries.size') do
        assert_raises(ApplicationMailer::DeliverySkipped) do
          RegistrationMailer.with(registration_verification: verification).email_verification.deliver_now
        end
      end
    end
  end
end
