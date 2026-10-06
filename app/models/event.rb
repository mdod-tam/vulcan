# frozen_string_literal: true

class Event < ApplicationRecord
  belongs_to :user
  belongs_to :auditable, polymorphic: true, optional: true

  # Old and new values for fields the audited record encrypts. Metadata is plain JSON, so it keeps
  # only those fields' names; AuditEventService.log moves the values here.
  encrypts :change_values

  validates :action, presence: true
  validate :validate_metadata_structure

  before_create do
    self.user_agent = Current.user_agent
    self.ip_address = Current.ip_address
  end

  # Ensure metadata is always a hash
  def metadata
    super || {}
  end

  # The recorded changes, with values of encrypted fields restored. Read changes through this, not
  # metadata['changes'], which holds an empty placeholder for each of those fields.
  def field_changes
    stored = change_values.present? ? JSON.parse(change_values) : {}
    (metadata['changes'] || {}).to_h { |field, change| [field, stored.fetch(field, change)] }
  end

  # Scope for finding events by metadata key/value
  scope :with_metadata, lambda { |key, value|
    where('metadata @> ?', { key => value }.to_json)
  }

  private

  def validate_metadata_structure
    return if metadata.is_a?(Hash)

    errors.add(:metadata, 'must be a JSON object')
  end
end
