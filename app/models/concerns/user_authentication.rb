# frozen_string_literal: true

# Password, lockout, sign-in tracking, password reset, and second-factor state for User.
module UserAuthentication
  extend ActiveSupport::Concern

  # Maryland's external-user authentication guidance requires at least 12 characters. Forms read this
  # for their minlength and hint, so the browser and the server state the same rule.
  PASSWORD_MIN_LENGTH = 12
  MAX_LOGIN_ATTEMPTS = 5
  LOCK_DURATION = 1.hour
  TOTP_MAX_ATTEMPTS = 5
  TOTP_ATTEMPT_PERIOD = 15.minutes
  TWO_FACTOR_SIGN_IN_EXPIRY = 10.minutes

  included do
    # has_secure_password defines its own :password_reset token from the password salt.
    # Register the stronger definition below after it, so that ours replaces it.
    has_secure_password

    # The token binds to the password digest and to each route that can receive a reset link:
    # the login email and the phone. A change to any of them revokes links already sent.
    # The phone is necessary because SMS also delivers reset links. For example, a duplicate merge
    # that replaces a phone must revoke the link sent to the discarded number.
    # This is separate from clearing the legacy reset_password_token and reset_password_sent_at
    # columns on retirement. Do not combine the two mechanisms.
    generates_token_for :password_reset, expires_in: 20.minutes do
      password_reset_token_fingerprint
    end

    # Match Rails' password-reset salt binding without storing the password digest in the browser.
    generates_token_for :two_factor_sign_in, expires_in: TWO_FACTOR_SIGN_IN_EXPIRY do
      [password_salt&.last(10), security_version]
    end

    has_many :sessions, dependent: :destroy
    before_update :advance_password_security_version, if: :will_save_change_to_password_digest?
    after_update :revoke_sessions_after_password_change, if: :saved_change_to_password_digest?

    has_many :webauthn_credentials, dependent: :destroy
    has_many :totp_credentials, dependent: :destroy
    has_many :sms_credentials, dependent: :destroy

    validates :password, presence: true, on: :password_change
    validates :password, length: { minimum: PASSWORD_MIN_LENGTH }, if: -> { password.present? }
    validates :reset_password_token, uniqueness: true, allow_nil: true
  end

  class_methods do
    def digest(string)
      cost = ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
      BCrypt::Password.create(string, cost: cost)
    end
  end

  # A read only. An expired lock stays on the row until the next failed login or sign-in clears it under the
  # user lock, so this method writes nothing.
  def account_locked?
    locked_at.present? && locked_at > LOCK_DURATION.ago
  end

  # Counts one failed password attempt and applies the lock at MAX_LOGIN_ATTEMPTS. The counter and locked_at
  # change in one write under the user lock, so concurrent failures cannot lose a count or miss the lock.
  # An expired lock starts a fresh count.
  def record_failed_login!
    with_lock do
      attempts = login_lock_expired? ? 1 : failed_attempts.to_i + 1
      now = Time.current

      # Skip validations and callbacks so that invalid legacy profile data cannot block counting or locking.
      # Nothing depends on these bookkeeping columns. This code sets updated_at itself.
      # rubocop:disable-next Rails/SkipsModelValidations
      update_columns(
        failed_attempts: attempts,
        locked_at: (now if attempts >= MAX_LOGIN_ATTEMPTS),
        updated_at: now
      )
    end
  end

  # Records a successful sign-in under the user lock and returns true. While the account is locked it writes
  # nothing and returns false, so the caller must not start a session. An expired lock does not refuse: this
  # write clears it with the counter.
  def track_sign_in!(ip)
    with_lock do
      if account_locked?
        false
      else
        # Skip validations and callbacks so that invalid legacy profile data cannot block sign-in tracking.
        # Nothing depends on these bookkeeping columns. This code sets updated_at itself.
        # rubocop:disable-next Rails/SkipsModelValidations
        update_columns(
          last_sign_in_at: Time.current,
          last_sign_in_ip: ip,
          failed_attempts: 0,
          locked_at: nil,
          updated_at: Time.current
        )
        true
      end
    end
  end

  def second_factor_enabled?
    webauthn_credentials.exists? ||
      totp_credentials.exists? ||
      sms_credentials.verified.exists?
  end

  # Authority writers call this under the canonical user lock in their transaction.
  # Factor usage counters and ordinary profile changes do not change authority.
  def advance_security_version!
    update!(security_version: security_version + 1)
  end

  def verify_webauthn(assertion, challenge:)
    return if challenge.blank? || !valid_webauthn_assertion?(assertion)

    with_lock do
      next unless public_login_active?

      response = WebAuthn::Credential.from_get(assertion)
      credential = webauthn_credentials.find_by(external_id: response.id)
      next unless credential

      response.verify(challenge, public_key: credential.public_key, sign_count: credential.sign_count)
      credential.update!(sign_count: response.sign_count)
      credential
    end
  rescue WebAuthn::Error, OpenSSL::PKey::PKeyError, ArgumentError, JSON::ParserError, CBOR::UnpackError
    nil
  end

  # The account row serializes guesses across browsers, IP addresses, and application workers.
  # Restarting the password step does not clear this failure window.
  def verify_totp(code)
    with_lock do
      if public_login_active?
        reset_totp_attempt_window if totp_attempt_window_started_at.nil? ||
                                     totp_attempt_window_started_at <= TOTP_ATTEMPT_PERIOD.ago
        totp_failed_attempts >= TOTP_MAX_ATTEMPTS ? :rate_limited : check_totp_code(code)
      else
        :inactive
      end
    end
  end

  private

  def valid_webauthn_assertion?(assertion)
    return false unless assertion.is_a?(Hash) && assertion['response'].is_a?(Hash)

    required = assertion.values_at('id', 'rawId', 'type') +
               assertion['response'].values_at('clientDataJSON', 'authenticatorData', 'signature')
    return false unless required.all? { |value| value.is_a?(String) && value.present? }

    client_data = JSON.parse(WebAuthn.configuration.relying_party.encoder.decode(assertion['response']['clientDataJSON']))
    client_data.is_a?(Hash) && client_data.values_at('type', 'challenge', 'origin').all?(String)
  end

  def login_lock_expired?
    locked_at.present? && !account_locked?
  end

  def reset_totp_attempt_window
    assign_attributes(totp_failed_attempts: 0, totp_attempt_window_started_at: Time.current)
  end

  def check_totp_code(code)
    credentials, matched_at = matching_totp_credentials(code)
    if credentials
      credentials.each { |credential| credential.update!(last_used_at: Time.at(matched_at).utc) }
      persist_totp_attempt_budget!(attempts: 0, window_started_at: nil)
      :verified
    else
      persist_totp_attempt_budget!(attempts: totp_failed_attempts + 1,
                                   window_started_at: totp_attempt_window_started_at)
      if totp_failed_attempts >= TOTP_MAX_ATTEMPTS
        # A failed audit write must not roll back the budget and reopen guesses.
        ActiveRecord.after_all_transactions_commit do
          PublicAuditActor.log_audit(
            action: 'two_factor_verification_rate_limited', auditable: self,
            metadata: { factor: 'totp', target_user_id: id }
          )
        end
        :rate_limited
      else
        :invalid
      end
    end
  end

  def persist_totp_attempt_budget!(attempts:, window_started_at:)
    # These locked auth counters do not change profile, contact, or password fields.
    # Skip their unrelated validations/callbacks; the lockout audit is recorded explicitly above.
    # rubocop:disable-next Rails/SkipsModelValidations
    updated = update_columns(totp_failed_attempts: attempts, totp_attempt_window_started_at: window_started_at,
                             updated_at: Time.current)
    raise ActiveRecord::RecordNotSaved, 'TOTP attempt budget could not be persisted' unless updated
  end

  def matching_totp_credentials(code)
    return unless code.is_a?(String) && code.bytesize == 6 && code.match?(/\A[0-9]{6}\z/)

    # Repeated enrollment could previously store the same seed more than once.
    totp_credentials.group_by(&:secret).each do |secret, credentials|
      candidate = credentials.max_by(&:last_used_at)
      matched_at = ROTP::TOTP.new(secret).verify(
        code, drift_behind: 30, drift_ahead: 30, after: candidate.last_used_at
      )
      return [credentials, matched_at] if matched_at
    end
    nil
  end

  def revoke_sessions_after_password_change
    # Reload so a previously loaded association cannot leave a newer session active.
    sessions.reload.destroy_all
    ContactChangeRequest.unresolved.where(user_id: id).find_each { |change| change.update!(canceled_at: Time.current) }
  end

  # Password changes already own session revocation here. Advance pending-proof
  # authority in that same password write, without a recursive User save.
  def advance_password_security_version
    self.security_version += 1
  end

  # Payload for the :password_reset token above. The password digest is the HMAC key
  # because the schema has no separate password salt column.
  # The lookup normalizers make sure that a format-only change does not revoke the token.
  # The separator prevents collisions between different email and phone splits.
  def password_reset_token_fingerprint
    contact_authority = [
      User.normalize_email(email).to_s,
      PhoneNumber.normalize(phone).to_s
    ].join("\x1f")

    OpenSSL::HMAC.hexdigest('SHA256', password_digest.to_s, contact_authority)
  end
end
