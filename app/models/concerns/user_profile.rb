# frozen_string_literal: true

# Concern for handling user profile data, validations, and formatting.
module UserProfile
  extend ActiveSupport::Concern

  included do
    # Callbacks
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
    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :dependent_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validate :email_must_be_unique
    validate :phone_must_be_unique
    validate :phone_number_must_be_valid, if: :phone_changed?
    validate :dependent_phone_number_must_be_valid, if: :dependent_phone_changed?
    validate :constituent_must_have_disability, if: :validate_constituent_disability?
    validate :validate_address_for_letter_preference

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

  def disabilities
    disability_list = []
    disability_list << 'Hearing Disability' if hearing_disability
    disability_list << 'Vision Disability' if vision_disability
    disability_list << 'Speech Disability' if speech_disability
    disability_list << 'Mobility Disability' if mobility_disability
    disability_list << 'Cognition Disability' if cognition_disability
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

  def format_phone_number
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

    Event.create!(
      user: actor,
      action: action,
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

    existing = User.exists_with_phone?(phone, excluding_id: id)
    errors.add(:phone, 'has already been taken') if existing
  rescue StandardError => e
    Rails.logger.warn "Phone uniqueness check failed: #{e.message}"
  end
end
