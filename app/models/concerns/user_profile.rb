# frozen_string_literal: true

module UserProfile
  extend ActiveSupport::Concern

  # The phone_type enum includes email and letter preferences as legacy values.
  # For a real phone, validate submitted phone_type against these telephone routes, not the full enum.
  REAL_PHONE_TYPES = %w[voice videophone text].freeze
  # Profile changes made by someone other than the user. They record the changed user in
  # metadata['user_id'] and the person who made the change as the event's user.
  PROFILE_CHANGE_ON_BEHALF_ACTIONS = %w[profile_updated_by_guardian profile_updated_by_admin].freeze
  # Profile-change audit events record that these changed, not their values.
  VALUELESS_AUDIT_FIELDS = %w[date_of_birth].freeze

  included do
    attr_accessor :phone_type_submitted

    # The merge service sets merge_in_progress to bypass the admin contact guard during contact transfer.
    # It sets retiring_for_merge on the duplicate to bypass delivery validation during retirement.
    attr_accessor :merge_in_progress, :retiring_for_merge

    before_validation :normalize_email_fields
    before_validation :normalize_communication_preference_for_undeliverable_email
    before_validation :format_phone_number
    before_save :format_phone_number, if: :phone_changed?
    after_save :log_profile_changes, if: :saved_changes_to_profile_fields?

    # Deterministic encryption permits equality queries on the marked fields.
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

    enum :status, { inactive: 0, active: 1, suspended: 2 }, default: :active
    # Official documents use communication_preference. Questions use phone_type.
    enum :communication_preference, { email: 0, letter: 1 }, default: :email, prefix: :deliver_via
    enum :phone_type, {
      voice: 'voice',
      videophone: 'videophone', # ASL videophone call
      text: 'text',             # Text/SMS message
      contact_email: 'email',
      contact_letter: 'letter'
    }, default: :voice
  end

  def full_name
    [first_name, last_name].compact.join(' ')
  end

  # The column is encrypted text holding ISO dates, so reading goes through the same parser as
  # writing. Date.parse would read a stray value day-first and answer with a different date.
  def date_of_birth
    raw_value = super
    return nil if raw_value.blank?

    DateInputNormalizer.normalize(raw_value).tap do |date|
      Rails.logger.warn "Invalid date format for user #{id}" if date.nil?
    end
  end

  # Unreadable input is never stored: it would reach the encrypted column and identity lookups.
  # It is kept on the instance only so a re-rendered form shows what the person typed.
  def date_of_birth=(value)
    normalized_date = DateInputNormalizer.normalize(value)
    @rejected_date_of_birth_input = normalized_date.nil? && value.present? ? value.to_s : nil
    super(normalized_date)
  end

  attr_reader :rejected_date_of_birth_input

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
    errors.add(:date_of_birth, :invalid) if rejected_date_of_birth_input
  end

  def validate_address_for_letter_preference
    return if retiring_for_merge
    return unless communication_preference.to_s == 'letter'

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
      next unless saved_change_to_attribute?(field)

      old_value, new_value = saved_change_to_attribute(field)
      # Event metadata is not encrypted, so a value stored here would undo the column's encryption.
      changed_attributes[field] = VALUELESS_AUDIT_FIELDS.include?(field) ? {} : { old: old_value, new: new_value }
    end

    # The merge owns duplicate_user_merged. Do not add profile events for its contact transfers.
    return if changed_attributes.blank? || merge_in_progress || retiring_for_merge

    actor = Current.user || self
    action = if Current.paper_context
               'profile_created_by_admin_via_paper'
             elsif actor == self
               'profile_updated'
             elsif actor.admin?
               'profile_updated_by_admin'
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
    return unless existing

    return add_portal_self_registration_unavailable_contact_error if portal_self_registration?

    errors.add(:email, 'has already been taken')
  rescue StandardError => e
    Rails.logger.warn "Email uniqueness check failed: #{e.message}"
  end

  def phone_must_be_unique
    return if phone.blank?
    return unless User.exists_with_phone?(phone, excluding_id: id)

    conflicting_user = User.find_by_phone(phone)
    return add_portal_self_registration_unavailable_contact_error if portal_self_registration? && conflicting_user.present? && !conflicting_user.real_email?

    errors.add(:phone, 'has already been taken')
  rescue StandardError => e
    Rails.logger.warn "Phone uniqueness check failed: #{e.message}"
  end

  def paper_context_no_email?
    Current.paper_context && email.blank?
  end

  def paper_context_no_phone?
    Current.paper_context && phone.blank?
  end

  # Persisted phone-only and address-only constituents can remain editable without an email.
  # This validation exception does not grant public portal access.
  def email_optional?
    retiring_for_merge || paper_context_no_email? ||
      (persisted? && constituent_user_type? && portal_phone_only_without_email?) ||
      (persisted? && constituent_user_type? && address_only_contact?)
  end

  def validate_admin_contact_update?
    !Current.paper_context && !merge_in_progress && constituent_user_type?
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
    return if retiring_for_merge || !deliver_via_email?
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

    errors.add(
      :base,
      :portal_self_registration_requires_email,
      support_email: portal_registration_support_email,
      support_phone: portal_registration_support_phone
    )
  end

  def normalize_portal_self_registration_phone_type
    self.phone_type = :contact_email if phone.blank?
  end

  def portal_self_registration_phone_type_matches_phone
    return if phone.blank?
    return if phone_type_submitted && REAL_PHONE_TYPES.include?(phone_type)

    self.phone_type = nil
    errors.add(:phone_type, :portal_self_registration_phone_type_required)
  end

  def portal_registration_support_email
    Policy.get('support_email') || 'mat.program1@maryland.gov'
  end

  def portal_registration_support_phone
    ProgramContact.support_phone_display
  end

  def add_portal_self_registration_unavailable_contact_error
    errors.add(:base, :portal_self_registration_unavailable_contact,
               support_email: portal_registration_support_email, support_phone: portal_registration_support_phone)
  end

  def was_address_only_contact?
    return true if new_record?

    prior = User.new(email: attribute_in_database(:email), phone: attribute_in_database(:phone))
    !prior.real_email? && !prior.real_phone?
  end
end
