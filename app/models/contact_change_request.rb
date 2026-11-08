# frozen_string_literal: true

class ContactChangeRequest < ApplicationRecord
  LIFETIME = 20.minutes
  EMAIL_PROOFS = %w[old_email new_email].freeze
  DELIVERY_ROLES = %w[old_email new_email old_notice old_completed new_completed].freeze
  FINAL_DELIVERY_STATES = %w[submitted suppressed].freeze

  class Refused < StandardError; end

  belongs_to :user
  belongs_to :session, optional: true
  has_many :email_delivery_attempts, as: :origin, dependent: :nullify
  encrypts :old_value, :proposed_value, :notification_email

  before_validation :normalize_contact
  validates :kind, inclusion: { in: %w[email phone] }
  validates :locale, inclusion: { in: %w[en es] }
  validates :expires_at, :security_version, presence: true
  validates :proposed_value, length: { maximum: 254 }
  validate :valid_proposed_contact

  scope :unresolved, -> { where(completed_at: nil, canceled_at: nil) }

  def pending?
    completed_at.nil? && canceled_at.nil? && expires_at && expires_at > Time.current
  end

  def ready?
    (proposed_value.blank? || new_confirmed_at.present?) && (!old_confirmation_required? || old_confirmed_at.present?)
  end

  def sms?
    kind == 'phone' && phone_type == 'text' && proposed_value.present?
  end

  def staff_assistance?
    kind == 'phone' && proposed_value.present? && !sms?
  end

  def require_current!(locked_user:)
    stored = kind == 'email' ? locked_user.email : locked_user.phone
    raise Refused unless pending? && locked_user.id == user_id && locked_user.public_login_active? &&
                         locked_user.security_version == security_version && stored == old_value
  end

  def proof_token(role)
    raise ArgumentError, 'Unknown confirmation purpose' unless EMAIL_PROOFS.include?(role)

    signed_id(expires_at: expires_at, purpose: "contact_change_#{role}")
  end

  def self.find_for_proof(token, role)
    return unless EMAIL_PROOFS.include?(role)

    row = find_signed(token, purpose: "contact_change_#{role}")
    row if row&.pending? && row.kind == 'email'
  end

  def sms_owner
    "contact-change:#{id}:#{session_id}:#{security_version}"
  end

  def prepare_delivery!(role)
    raise ArgumentError, 'Unknown delivery role' unless DELIVERY_ROLES.include?(role)

    action = EMAIL_PROOFS.include?(role) ? 'ContactChangeMailer#verification' : 'ContactChangeMailer#security_notice'
    decision, context = EmailDelivery.issuance(action, params: { user: user })
    self.delivery_states = delivery_states.merge(role => decision&.outcome&.to_s || 'pending')
    self.delivery_contexts = delivery_contexts.merge(role => context)
  end

  def prepare_requested_deliveries!
    if kind == 'email'
      prepare_delivery!('new_email')
      prepare_delivery!(old_confirmation_required? ? 'old_email' : 'old_notice') if notification_email.present?
    elsif notification_email.present?
      prepare_delivery!('old_notice')
    end
  end

  def prepare_completed_deliveries!
    prepare_delivery!('old_completed') if notification_email.present?
    prepare_delivery!('new_completed') if kind == 'email' && proposed_value.present?
  end

  def completion_notices_queued?
    delivery_states.slice('old_completed', 'new_completed').values.none? { |state| state.in?(%w[pending error]) }
  end

  # This row is the durable delivery intent. Failed enqueue can be retried from
  # the account page without changing proof lifetime or contact authority.
  def enqueue_deliveries!(reconcile: false)
    delivery_states.each do |role, state|
      next unless state.in?(reconcile ? %w[pending error queued unknown] : %w[pending error])
      next if EMAIL_PROOFS.include?(role) && !pending?

      begin
        job = ContactChangeDeliveryJob.perform_later(id, role)
        set_delivery_state!(role, job&.successfully_enqueued? ? 'queued' : 'error')
      rescue StandardError => e
        Rails.logger.warn("Contact notice enqueue failed: #{e.class.name}")
        set_delivery_state!(role, 'error')
      end
    end
  end

  def set_delivery_state!(role, state)
    with_lock do
      update!(delivery_states: delivery_states.merge(role => state)) unless delivery_states[role].in?(FINAL_DELIVERY_STATES)
    end
  end

  def delivery_email(role)
    %w[new_email new_completed].include?(role) ? proposed_value : notification_email
  end

  private

  def normalize_contact
    self.proposed_value = if kind == 'email'
                            User.normalize_email(proposed_value)
                          elsif proposed_value.present?
                            PhoneNumber.normalize(proposed_value) || proposed_value.to_s.strip
                          end
  end

  def valid_proposed_contact
    if kind == 'email'
      errors.add(:proposed_value, :invalid) unless User.real_email_address?(proposed_value)
    elsif proposed_value.present?
      errors.add(:proposed_value, :invalid) unless PhoneNumber.real?(proposed_value)
      errors.add(:phone_type, :inclusion) unless %w[text voice videophone].include?(phone_type)
    end
  end
end
