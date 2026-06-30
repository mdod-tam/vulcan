# frozen_string_literal: true

require 'bcrypt'

# User model that serves as the base class for all user types in the system
class User < ApplicationRecord
  include UserAuthentication
  include UserRolesAndCapabilities
  include UserProfile
  include UserGuardianship
  include UserEmailSearch

  # Ensure duplicate review flag is accessible
  attr_accessor :needs_duplicate_review unless column_names.include?('needs_duplicate_review')

  # Class methods
  def self.normalize_email(email_value)
    email_value.to_s.strip.downcase.presence
  end

  def self.normalize_phone(phone_value)
    return nil if phone_value.blank?

    digits = phone_value.to_s.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    return digits.gsub(/(\d{3})(\d{3})(\d{4})/, '\1-\2-\3') if digits.length == 10

    phone_value.to_s
  end

  def self.synthetic_dependent_phone?(phone_value)
    normalize_phone(phone_value).to_s.gsub(/\D/, '').start_with?('000')
  end

  def self.system_user
    if @system_user.nil? || !system_user_valid?(@system_user)
      @system_user = find_by_email('system@mdmat.org')
      if @system_user.nil?
        @system_user = User.create!(
          first_name: 'System',
          last_name: 'User',
          email: 'system@mdmat.org',
          password: SecureRandom.hex(32),
          type: 'Users::Administrator',
          verified: true
        )
      elsif !@system_user.admin?
        @system_user.update!(type: 'Users::Administrator')
      end
    end
    @system_user
  end

  def self.system_user_valid?(user)
    user.persisted? && user.admin? && exists?(user.id)
  end
  private_class_method :system_user_valid?

  # Rails 8 encryption helper methods for encrypted queries
  def self.find_by_email(email_value)
    normalized_email = normalize_email(email_value)
    return nil if normalized_email.blank?

    # With transparent encryption, we can use regular find_by
    User.find_by(email: normalized_email)
  rescue StandardError => e
    Rails.logger.warn "find_by_email failed: #{e.message}"
    nil
  end

  def self.find_by_phone(phone_value)
    normalized_phone = normalize_phone(phone_value)
    return nil if normalized_phone.blank?

    User.find_by(phone: normalized_phone)
  rescue StandardError => e
    Rails.logger.warn "find_by_phone failed: #{e.message}"
    nil
  end

  def self.login_identifier_looks_like_email?(contact)
    contact.to_s.strip.include?('@')
  end

  def self.login_identifier_valid_email?(contact)
    normalized = contact.to_s.strip
    normalized.match?(URI::MailTo::EMAIL_REGEXP)
  end

  def self.find_by_login_identifier(contact)
    normalized = contact.to_s.strip.presence
    return nil if normalized.blank?

    if login_identifier_looks_like_email?(normalized)
      return nil unless login_identifier_valid_email?(normalized)

      user = find_by_email(normalized)
      return nil if user.blank? || system_generated_email?(user.email)

      return user
    end

    phone_user = find_by_phone(normalized)
    return nil if phone_user.blank?
    return nil if placeholder_phone?(phone_user.phone)

    phone_user
  end

  def self.placeholder_phone?(phone)
    synthetic_dependent_phone?(phone)
  end

  def self.system_generated_email?(email)
    return false if email.blank?

    normalize_email(email).to_s.end_with?('@system.matvulcan.local')
  end

  def self.exists_with_email?(email_value, excluding_id: nil)
    normalized_email = normalize_email(email_value)
    return false if normalized_email.blank?

    query = User.where(email: normalized_email)
    query = query.where.not(id: excluding_id) if excluding_id
    query.exists?
  rescue StandardError => e
    Rails.logger.warn "exists_with_email? failed: #{e.message}"
    false
  end

  def self.exists_with_phone?(phone_value, excluding_id: nil)
    normalized_phone = normalize_phone(phone_value)
    return false if normalized_phone.blank?

    query = User.where(phone: normalized_phone)
    query = query.where.not(id: excluding_id) if excluding_id
    query.exists?
  rescue StandardError => e
    Rails.logger.warn "exists_with_phone? failed: #{e.message}"
    false
  end

  # Callbacks
  after_save :reset_all_caches

  # Associations
  has_many :events, dependent: :destroy
  has_many :received_notifications,
           class_name: 'Notification',
           foreign_key: :recipient_id,
           dependent: :destroy,
           inverse_of: :recipient
  has_many :applications, inverse_of: :user, dependent: :nullify
  has_many :income_verified_applications,
           class_name: 'Application',
           foreign_key: :income_verified_by_id,
           inverse_of: :income_verified_by,
           dependent: :nullify

  has_and_belongs_to_many :products,
                          join_table: 'products_users'

  # Scopes
  scope :ordered_by_name, -> { order(:first_name) }

  # Subject of a paper application (existing-adult flow). Used at trust boundaries;
  # do not rely on UI-only filtering or raw +existing_constituent_id+.
  def paper_applicant_candidate?
    constituent?
  end

  private

  def reset_all_caches
    @available_capabilities = nil
    @inherent_capabilities = nil
    @loaded_capabilities = nil
  end

  def active_application
    applications.where.not(status: 'draft').order(created_at: :desc).first
  end
end
