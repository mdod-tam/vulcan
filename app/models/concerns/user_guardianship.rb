# frozen_string_literal: true

# Concern for handling guardian/dependent relationships and related logic.
module UserGuardianship
  extend ActiveSupport::Concern

  # Identifies the stored value and record that own one dependent contact field.
  # +source+ describes the field shape; delivery workflows map guardian ownership
  # to their application-specific provenance.
  OwnedContact = Data.define(:value, :owner, :source)

  included do
    # Guardian/Dependent Associations
    has_many :guardian_relationships_as_guardian,
             class_name: 'GuardianRelationship',
             foreign_key: 'guardian_id',
             dependent: :destroy,
             inverse_of: :guardian_user
    has_many :dependents, through: :guardian_relationships_as_guardian, source: :dependent_user

    has_many :guardian_relationships_as_dependent,
             class_name: 'GuardianRelationship',
             foreign_key: 'dependent_id',
             dependent: :destroy,
             inverse_of: :dependent_user
    has_many :guardians, through: :guardian_relationships_as_dependent, source: :guardian_user

    has_many :managed_applications, # Applications where this user is the managing_guardian
             class_name: 'Application',
             foreign_key: 'managing_guardian_id',
             inverse_of: :managing_guardian,
             dependent: :nullify

    # Guardian relationship scopes
    scope :with_dependents, lambda {
      joins(:guardian_relationships_as_guardian).distinct
    }

    scope :with_guardians, lambda {
      joins(:guardian_relationships_as_dependent).distinct
    }

    # Authorization scopes - consistent with Application model pattern
    # Returns dependents that can be edited/viewed by the specified guardian
    # Uses group instead of distinct to avoid JSON column equality operator issues
    scope :editable_by_guardian, lambda { |guardian_user|
      joins(:guardian_relationships_as_dependent)
        .where(guardian_relationships: { guardian_id: guardian_user.id })
        .group('users.id')
    }

    # Alias for consistency with Application model
    scope :accessible_by_guardian, lambda { |guardian_user|
      editable_by_guardian(guardian_user)
    }
  end

  # Guardian/dependent helper methods
  def guardian?
    guardian_relationships_as_guardian.any?
  end

  def dependent?
    guardian_relationships_as_dependent.any?
  end

  # Returns all applications for dependents of this guardian user
  def dependent_applications
    return Application.none unless guardian?

    Application.where(user_id: dependents.pluck(:id))
  end

  # Returns relationship types for a specific dependent
  def relationship_types_for_dependent(dependent_user)
    guardian_relationships_as_guardian
      .where(dependent_id: dependent_user.id)
      .pluck(:relationship_type)
  end

  # Helper methods for dependent contact information
  def effective_email
    return email unless dependent?

    dependent_email_contact(contact_guardian: guardian_for_contact)&.value
  end

  def effective_phone
    return phone unless dependent?

    dependent_phone_contact(contact_guardian: guardian_for_contact)&.value
  end

  def effective_phone_type
    return phone_type unless dependent?

    dependent_phone_contact(contact_guardian: guardian_for_contact)&.owner&.phone_type || phone_type
  end

  def effective_communication_preference
    if dependent? && guardian_for_contact
      guardian_for_contact.communication_preference
    else
      communication_preference
    end
  end

  def effective_locale
    return locale unless dependent?

    dependent_email_contact(contact_guardian: guardian_for_contact)&.owner&.locale || locale
  end

  # +effective_locale+ narrowed to something I18n will actually accept, or nil when this user has
  # none set or carries a value the app no longer ships. Stored locales are not validated against
  # the available set, so callers that pass one to +I18n.t+ or +I18n.with_locale+ must go through
  # here and supply their own fallback; an unsupported value raises I18n::InvalidLocale.
  def effective_message_locale
    candidate = effective_locale.to_s
    return if candidate.blank?

    candidate.to_sym if I18n.available_locales.include?(candidate.to_sym)
  end

  # Get the primary guardian for contact purposes
  def guardian_for_contact
    return nil unless dependent?

    @guardian_for_contact ||= if guardian_relationships_as_dependent.loaded?
                                guardian_relationships_as_dependent.find(&:guardian_user)&.guardian_user
                              else
                                guardian_relationships_as_dependent
                                  .joins(:guardian_user)
                                  .first&.guardian_user
                              end
  end

  # Authorization methods - consistent with Application model pattern
  # Checks if a user (guardian) can edit this dependent
  def editable_by_guardian?(guardian_user)
    return false unless guardian_user
    return false unless dependent?

    # Guardian can edit if they have a guardian relationship with this dependent
    guardians.include?(guardian_user)
  end

  def accessible_by_guardian?(guardian_user)
    # For now, accessible means editable (strict ownership)
    # Could be expanded in the future to allow read-only access
    editable_by_guardian?(guardian_user)
  end

  def viewable_by_guardian?(guardian_user)
    # Alias for consistency with Application model and Rails authorization patterns
    accessible_by_guardian?(guardian_user)
  end

  # Paper intake displays dependent-owned contact separately from synthetic primary fields.
  def paper_intake_own_email(guardian: nil)
    guardian ||= guardian_for_contact
    contact = dependent_email_contact(contact_guardian: guardian)
    contact.value if contact&.owner == self
  end

  def paper_intake_own_phone(guardian: nil)
    guardian ||= guardian_for_contact
    contact = dependent_phone_contact(contact_guardian: guardian)
    contact.value if contact&.owner == self
  end

  def paper_intake_uses_guardian_email?(guardian: nil)
    dependent? && paper_intake_own_email(guardian: guardian).blank?
  end

  def paper_intake_uses_guardian_phone?(guardian: nil)
    dependent? && paper_intake_own_phone(guardian: guardian).blank?
  end

  # Canonical interpretation of the contact shapes written by
  # Applications::GuardianDependentManagementService. Callers may supply a
  # preloaded guardian scope; otherwise the dependent's relationships define it.
  def dependent_email_contact(contact_guardian:, related_guardians: nil)
    dependent_contact(
      :email,
      contact_guardian: contact_guardian,
      related_guardians: related_guardians,
      missing_snapshot_fallback: :guardian
    )
  end

  def dependent_phone_contact(contact_guardian:, related_guardians: nil)
    dependent_contact(
      :phone,
      contact_guardian: contact_guardian,
      related_guardians: related_guardians,
      missing_snapshot_fallback: :primary
    )
  end

  # Address strategy is not persisted. Retain one deliberately bounded inference:
  # only a complete dependent address paired with an incomplete guardian address
  # can be identified as dependent-owned from stored state alone.
  def dependent_mailing_address_owner(contact_guardian:)
    return self unless dependent? && contact_guardian
    return self if complete_mailing_address? && !contact_guardian.complete_mailing_address?

    contact_guardian
  end

  private

  def dependent_contact(field, contact_guardian:, related_guardians:, missing_snapshot_fallback:)
    return unless dependent?

    dependent_value = usable_contact_value(field, public_send("dependent_#{field}"))
    primary_value = public_send(field) if public_send("real_#{field}?")
    if dependent_value
      related_guardians ||= guardians.to_a
      guardian_scope = [contact_guardian, *Array(related_guardians)].compact.uniq(&:id)
      return contact_from_snapshot(field, dependent_value, primary_value, contact_guardian, guardian_scope)
    end

    # Rows predating strategy snapshots are ambiguous. Preserve each field's
    # established fallback explicitly instead of deriving one field from another.
    contact_without_snapshot(field, primary_value, contact_guardian, missing_snapshot_fallback)
  end

  def contact_from_snapshot(field, dependent_value, primary_value, contact_guardian, guardians)
    matching_guardian = guardian_matching(field, dependent_value, guardians)
    contact_guardian_owns_snapshot = matching_guardian&.id == contact_guardian&.id
    if contact_guardian_owns_snapshot
      guardian_value = guardian_contact_value(field, contact_guardian)
      return owned_contact(guardian_value, contact_guardian, :guardian)
    end
    return owned_contact(primary_value, self, :constituent) if matching_guardian

    owned_contact(dependent_value, self, :dependent_contact)
  end

  def contact_without_snapshot(field, primary_value, contact_guardian, fallback)
    return owned_contact(primary_value, self, :constituent) if fallback == :primary && primary_value
    return owned_contact(guardian_contact_value(field, contact_guardian), contact_guardian, :guardian) if contact_guardian

    owned_contact(primary_value, self, :constituent)
  end

  def guardian_matching(field, value, guardians)
    normalized = normalize_contact(field, value)
    return if normalized.blank?

    guardians.find { |guardian| normalize_contact(field, guardian_contact_value(field, guardian)) == normalized }
  end

  def usable_contact_value(field, value)
    value if User.new(field => value).public_send("real_#{field}?")
  end

  def guardian_contact_value(field, guardian)
    guardian.public_send(field) if guardian.public_send("real_#{field}?")
  end

  def normalize_contact(field, value)
    User.public_send("normalize_#{field}", value).to_s
  end

  def owned_contact(value, owner, source)
    OwnedContact.new(value: value, owner: owner, source: source) if value.present?
  end
end
