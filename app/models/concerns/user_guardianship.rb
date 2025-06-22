# frozen_string_literal: true

# Concern for handling guardian/dependent relationships and related logic.
module UserGuardianship
  extend ActiveSupport::Concern

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
  end

  # Guardian/dependent helper methods
  def guardian?
    guardian_relationships_as_guardian.exists?
  end

  def dependent?
    guardian_relationships_as_dependent.exists?
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
    if dependent? && dependent_email.present?
      dependent_email
    elsif dependent? && guardian_for_contact
      guardian_for_contact.email
    else
      email
    end
  end

  def effective_phone
    if dependent? && dependent_phone.present?
      dependent_phone
    elsif dependent? && guardian_for_contact
      guardian_for_contact.phone
    else
      phone
    end
  end

  def effective_phone_type
    if dependent? && dependent_phone.present?
      phone_type # Use dependent's preferred phone type
    elsif dependent? && guardian_for_contact
      guardian_for_contact.phone_type
    end

    phone_type
  end

  def effective_communication_preference
    if dependent? && guardian_for_contact
      guardian_for_contact.communication_preference
    else
      communication_preference
    end
  end

  # Get the primary guardian for contact purposes
  def guardian_for_contact
    return nil unless dependent?

    @guardian_for_contact ||= guardian_relationships_as_dependent
                              .joins(:guardian_user)
                              .first&.guardian_user
  end
end
