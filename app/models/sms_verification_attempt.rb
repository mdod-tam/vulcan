# frozen_string_literal: true

# One provider challenge has one purpose and browser owner, even when Twilio
# reuses its code for another send to the same destination.
class SmsVerificationAttempt < ApplicationRecord
  TTL = 10.minutes
  COOLDOWN = 30.seconds
  CALL_TIMEOUT = 45.seconds
  MAX_CHECKS = 5
  PURPOSES = %w[login setup reauthentication contact_change].freeze

  class Refused < StandardError; end

  encrypts :phone_number
  validates :purpose, inclusion: { in: PURPOSES }
  validates :service_sid, :destination_digest, :phone_number, :owner_digest, :issued_at, :expires_at, :ownership_expires_at, presence: true

  def self.reserve_send!(service_sid:, phone:, purpose:, owner:, provider_lifetime: TTL)
    raise Refused if owner.blank? || PURPOSES.exclude?(purpose.to_s) || !PhoneNumber.real?(phone)
    raise Refused unless provider_lifetime.to_i.between?(120, 86_400)

    destination = AuthRateLimit.contact_digest(PhoneNumber.normalize(phone))
    result = nil
    transaction do
      # Serialize an absent destination too: SELECT FOR UPDATE cannot lock a row
      # that has not been inserted. The partial unique index remains a backstop.
      lock_destination!(service_sid, destination)
      now = Time.current
      current = live_attempt!(service_sid: service_sid, destination: destination, phone: phone, purpose: purpose, owner: owner,
                              provider_lifetime: provider_lifetime)
      raise Refused if current.provider_call_in_flight?(now)
      raise Refused if current.checks_count >= MAX_CHECKS
      raise Refused if current.expires_at <= now

      if current.last_sent_at && current.last_sent_at > now - COOLDOWN && current.verification_sid.present?
        result = [current, nil]
      else
        AuthRateLimit.check!(action: :sms_verification, scope: :contact, submitted_contact: phone)
        version = SecureRandom.hex(16)
        # A lost response can still create a provider token on this send.
        current.update!(send_version: version, sending_until: now + CALL_TIMEOUT, last_sent_at: now,
                        ownership_expires_at: [current.ownership_expires_at, now + provider_lifetime + CALL_TIMEOUT].max)
        result = [current, version]
      end
    end
    result
  end

  def self.reserve_check!(service_sid:, phone:, purpose:, owner:, verification_sid:)
    result = nil
    transaction do
      destination = AuthRateLimit.contact_digest(PhoneNumber.normalize(phone))
      lock_destination!(service_sid, destination)
      current = where(service_sid: service_sid, destination_digest: destination, finished_at: nil).take!
      now = Time.current
      unless current.owner_digest == digest_owner(owner) && current.purpose == purpose.to_s &&
             current.verification_sid == verification_sid && verification_sid.present? && current.expires_at > now
        raise Refused
      end
      raise Refused if current.checks_count >= MAX_CHECKS || current.provider_call_in_flight?(now)

      version = SecureRandom.hex(16)
      current.update!(check_version: version, checking_until: now + CALL_TIMEOUT, checks_count: current.checks_count + 1)
      result = [current, version]
    end
    result
  end

  def finish_send!(version:, sid:, provider_created_at: nil, provider_lifetime: TTL)
    with_lock do
      raise Refused unless send_version == version && finished_at.nil? && expires_at > Time.current

      deadline = provider_created_at ? [expires_at, provider_created_at + TTL, provider_created_at + provider_lifetime].min : expires_at
      ownership_deadline = provider_created_at ? [ownership_expires_at, provider_created_at + provider_lifetime].max : ownership_expires_at
      update!(verification_sid: sid, expires_at: deadline, ownership_expires_at: ownership_deadline, sending_until: nil)
    end
  end

  def finish_check!(version:, approved:, terminal:)
    with_lock do
      raise Refused unless check_version == version && finished_at.nil? && expires_at > Time.current

      # Local exhaustion or an ambiguous provider refusal does not end Twilio's
      # destination token. Keep ownership until its conservative deadline.
      update!(checking_until: nil, approved_at: (Time.current if approved),
              checks_count: terminal ? MAX_CHECKS : checks_count, finished_at: (Time.current if approved))
    end
  end

  def provider_result
    { success: true, verification_sid: verification_sid, status: 'pending',
      to: "+1#{PhoneNumber.national_digits(phone_number)}", channel: 'sms', code_expires_at: expires_at.to_i }
  end

  def provider_call_in_flight?(now)
    [sending_until, checking_until].compact.any? { |deadline| deadline > now }
  end

  def self.digest_owner(owner)
    OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, owner.to_s)
  end

  def self.live_attempt!(service_sid:, destination:, phone:, purpose:, owner:, provider_lifetime:)
    now = Time.current
    current = find_by(service_sid: service_sid, destination_digest: destination, finished_at: nil)
    if current && current.ownership_expires_at <= now
      current.update!(finished_at: now)
      current = nil
    end
    raise Refused if current && (current.owner_digest != digest_owner(owner) || current.purpose != purpose.to_s)

    current || create!(service_sid: service_sid, destination_digest: destination,
                       phone_number: PhoneNumber.normalize(phone), purpose: purpose,
                       owner_digest: digest_owner(owner), issued_at: now, expires_at: now + [TTL, provider_lifetime].min,
                       ownership_expires_at: now + provider_lifetime + CALL_TIMEOUT)
  end
  private_class_method :live_attempt!

  def self.lock_destination!(service_sid, destination)
    key = Digest::SHA256.digest("sms-verification:#{service_sid}:#{destination}").unpack1('q>')
    bind = ActiveRecord::Relation::QueryAttribute.new('lock_key', key, ActiveRecord::Type::Integer.new(limit: 8))
    connection.exec_query('SELECT pg_advisory_xact_lock($1)', 'SMS destination lock', [bind])
  end
  private_class_method :lock_destination!
end
