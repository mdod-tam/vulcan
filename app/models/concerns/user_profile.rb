# frozen_string_literal: true

# Concern for handling user profile data, validations, and formatting.
module UserProfile
  extend ActiveSupport::Concern

  PORTAL_SELF_REGISTRATION_PHONE_TYPES = %w[voice videophone text].freeze

  included do
    attr_accessor :phone_type_submitted

    # Callbacks
    before_validation :normalize_email_fields
    before_validation :normalize_communication_preference_for_undeliverable_email
    before_validation :format_phone_number
    before_save :format_phone_number, if: :phone_changed?
    after_save :log_profile_changes, if: :saved_changes_to_profile_fields?

    # PII Encryption
    encrypts :email, deterministic: true
    encrypts :phone, deterministic: true
    encrypts :dependent_email, deterministic: true
    encrypts :dependent_phone, deterministic: true
    encrypts :ssn_last4, deterministic: true
    encrypts :password_digest
    encrypts :date_of_birth, deterministic: true
    encrypts :physical_address_1
    encrypts :physical_address_2
    encrypts :city
    encrypts :state
    encrypts :zip_code

    # Validations
    validates :first_name, presence: true, length: { maximum: 50 }
    validates :last_name, presence: true, length: { maximum: 50 }
    validates :middle_initial, length: { maximum: 1 }, allow_blank: true
    validates :email, presence: true, unless: :email_optional?
    validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validates :dependent_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validate :email_must_be_unique
    validate :phone_must_be_unique
    validate :phone_number_must_be_valid, if: :phone_changed?, unless: :paper_context_no_phone?
    validate :dependent_phone_number_must_be_valid, if: :dependent_phone_changed?
    validate :date_of_birth_must_be_valid
    validate :constituent_must_have_disability, if: :validate_constituent_disability?
    validate :validate_address_for_letter_preference
    validate :email_delivery_requires_real_email
    validate :admin_contact_update_must_remain_reachable, on: :update, if: :validate_admin_contact_update?
    validate :self_service_profile_requires_email_backing, on: :update, if: :self_service_constituent_profile_update?
    before_validation :normalize_portal_self_registration_phone_type, if: :portal_self_registration?
    validate :portal_self_registration_phone_type_matches_phone, if: :portal_self_registration?
    validate :portal_self_registration_requires_email_backed_account, if: :portal_self_registration?

    # Enums
    enum :status, { inactive: 0, active: 1, suspended: 2 }, default: :active
    # communication_preference: where to send official documents (email vs physical mail)
    enum :communication_preference, { email: 0, letter: 1 }, default: :email, prefix: :deliver_via
    # phone_type serves as "preferred contact method" - how the user prefers to be reached for questions
    enum :phone_type, {
      voice: 'voice',           # Voice call to phone number
      videophone: 'videophone', # ASL videophone call
      text: 'text',             # Text/SMS message
      contact_email: 'email',   # Contact via email (stored as 'email' in DB)
      contact_letter: 'letter'  # Contact via physical mail (stored as 'letter' in DB)
    }, default: :voice
  end

  def full_name
    [first_name, last_name].compact.join(' ')
  end

  def date_of_birth
    raw_value = super
    return nil if raw_value.blank?
    return raw_value if raw_value.is_a?(Date)

    begin
      Date.parse(raw_value.to_s)
    rescue ArgumentError
      Rails.logger.warn "Invalid date format for user #{id}: #{raw_value}"
      nil
    end
  end

  def date_of_birth=(value)
    normalized_date = DateInputNormalizer.normalize(value)
    @invalid_date_of_birth = value.present? && normalized_date.blank?
    super(normalized_date || value.presence)
  end

  def disabilities
    disability_list = []
    disability_list << 'Hearing' if hearing_disability
    disability_list << 'Vision' if vision_disability
    disability_list << 'Speech' if speech_disability
    disability_list << 'Mobility' if mobility_disability
    disability_list << 'Cognition' if cognition_disability
    disability_list
  end

  def disability_selected?
    disability_flags = [
      hearing_disability, vision_disability, speech_disability,
      mobility_disability, cognition_disability
    ]
    disability_flags.any? { |flag| flag == true }
  end

  private

  def normalize_email_fields
    self.email = email.present? ? User.normalize_email(email) : nil
    self.dependent_email = dependent_email.present? ? User.normalize_email(dependent_email) : nil
  end

  def normalize_communication_preference_for_undeliverable_email
    return unless new_record?
    return if real_email?
    return if dependent_with_deliverable_contact_email?
    return unless deliver_via_email?

    self.communication_preference = :letter
  end

  def format_phone_number
    self.phone = nil if phone.blank?
    return if phone.blank?

    digits = phone.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    self.phone = if digits.length == 10
                   digits.gsub(/(\d{3})(\d{3})(\d{4})/, '\1-\2-\3')
                 else
                   phone
                 end
  end

  def phone_number_must_be_valid
    return if phone.blank?

    digits = phone.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    errors.add(:phone, 'must be a valid 10-digit US phone number') if digits.length != 10
  end

  def dependent_phone_number_must_be_valid
    return if dependent_phone.blank?

    digits = dependent_phone.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    errors.add(:dependent_phone, 'must be a valid 10-digit US phone number') if digits.length != 10
  end

  def date_of_birth_must_be_valid
    errors.add(:date_of_birth, 'must be in MM/DD/YYYY format') if @invalid_date_of_birth
  end

  def validate_address_for_letter_preference
    return unless communication_preference.to_s == 'letter' || communication_preference == :letter

    errors.add(:physical_address_1, 'is required when notification method is set to letter') if physical_address_1.blank?
    errors.add(:city, 'is required when notification method is set to letter') if city.blank?
    errors.add(:state, 'is required when notification method is set to letter') if state.blank?
    errors.add(:zip_code, 'is required when notification method is set to letter') if zip_code.blank?
  end

  def constituent_must_have_disability
    return unless type == 'Users::Constituent'

    errors.add(:base, 'At least one disability must be selected.') unless disability_selected?
  end

  def validate_constituent_disability?
    return false unless type == 'Users::Constituent'
    return false if new_record? && !@validate_disability_required

    applications.exists? || @validate_disability_required
  end

  def saved_changes_to_profile_fields?
    profile_fields = %w[first_name last_name email phone physical_address_1 physical_address_2 city state zip_code date_of_birth]
    profile_fields.any? { |field| saved_change_to_attribute?(field) }
  end

  def log_profile_changes
    changed_attributes = {}
    profile_fields = %w[first_name last_name email phone physical_address_1 physical_address_2 city state zip_code date_of_birth]

    profile_fields.each do |field|
      if saved_change_to_attribute?(field)
        old_value, new_value = saved_change_to_attribute(field)
        changed_attributes[field] = { old: old_value, new: new_value }
      end
    end

    return if changed_attributes.blank?

    actor = Current.user || self
    action = if Current.paper_context
               'profile_created_by_admin_via_paper'
             elsif actor == self
               'profile_updated'
             else
               'profile_updated_by_guardian'
             end

    AuditEventService.log(
      actor: actor,
      action: action,
      auditable: self,
      metadata: {
        user_id: id,
        changes: changed_attributes,
        updated_by: actor.id,
        timestamp: Time.current.iso8601
      }
    )
  end

  def email_must_be_unique
    return if email.blank?

    existing = User.exists_with_email?(email, excluding_id: id)
    errors.add(:email, 'has already been taken') if existing
  rescue StandardError => e
    Rails.logger.warn "Email uniqueness check failed: #{e.message}"
  end

  def phone_must_be_unique
    return if phone.blank?
    return unless User.exists_with_phone?(phone, excluding_id: id)

    conflicting_user = User.find_by_phone(phone)
    if portal_self_registration? && conflicting_user.present? && !conflicting_user.real_email?
      errors.add(
        :base,
        :portal_self_registration_unavailable_contact,
        support_email: portal_registration_support_email
      )
      return
    end

    errors.add(:phone, 'has already been taken')
  rescue StandardError => e
    Rails.logger.warn "Phone uniqueness check failed: #{e.message}"
  end

  # Check if we're in a paper context where email is not required
  def paper_context_no_email?
    Current.paper_context && email.blank?
  end

  # Check if we're in a paper context where phone is not required
  def paper_context_no_phone?
    Current.paper_context && phone.blank?
  end

  # Phone-only paper records store NULL email; password/profile saves must not require email.
  # They are not email-backed portal accounts and cannot use public portal sign-in.
  # Address-only users store NULL email/phone and remain editable outside paper context.
  def email_optional?
    paper_context_no_email? ||
      (persisted? && constituent_user_type? && portal_phone_only_without_email?) ||
      (persisted? && constituent_user_type? && address_only_contact?)
  end

  def validate_admin_contact_update?
    !Current.paper_context && constituent_user_type?
  end

  def self_service_constituent_profile_update?
    !Current.paper_context && Current.user == self && constituent_user_type?
  end

  def self_service_profile_requires_email_backing
    errors.add(:email, :blank) unless real_email?
  end

  def constituent_user_type?
    Users::FilterService::CONSTITUENT_TYPE_VALUES.include?(type)
  end

  def email_delivery_requires_real_email
    return unless deliver_via_email?
    return if real_email?
    return if dependent_with_deliverable_contact_email?

    errors.add(:communication_preference, 'requires an email address on file')
  end

  def dependent_with_deliverable_contact_email?
    return false unless User.system_generated_email?(email)
    return false if dependent_email.blank?
    return false unless dependent_email.to_s.match?(URI::MailTo::EMAIL_REGEXP)
    return false if User.system_generated_email?(dependent_email)

    true
  end

  def dependent_with_deliverable_contact_phone?
    return false if dependent_phone.blank?

    User.new(phone: dependent_phone).real_phone?
  end

  def admin_contact_update_must_remain_reachable
    return if real_email? || real_phone?
    return if dependent_with_deliverable_contact_email?
    return if dependent_with_deliverable_contact_phone?

    unless deliver_via_letter?
      errors.add(:communication_preference, 'must be letter when no email or phone is on file')
      return
    end

    return if was_address_only_contact?

    errors.add(:base, 'Cannot clear all contact information outside paper intake.')
  end

  def portal_self_registration?
    portal_self_registration == true
  end

  def portal_self_registration_requires_email_backed_account
    return if real_email?

    errors.add(:base, :portal_self_registration_requires_email)
  end

  def normalize_portal_self_registration_phone_type
    self.phone_type = :contact_email if phone.blank?
  end

  def portal_self_registration_phone_type_matches_phone
    return if phone.blank?
    return if phone_type_submitted && PORTAL_SELF_REGISTRATION_PHONE_TYPES.include?(phone_type)

    self.phone_type = nil
    errors.add(:phone_type, :portal_self_registration_phone_type_required)
  end

  def portal_registration_support_email
    Policy.get('support_email') || 'mat.program1@maryland.gov'
  end

  def was_address_only_contact?
    return true if new_record?

    prior = User.new(email: attribute_in_database(:email), phone: attribute_in_database(:phone))
    !prior.real_email? && !prior.real_phone?
  end
end
