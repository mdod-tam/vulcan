# frozen_string_literal: true

class Event < ApplicationRecord
  belongs_to :user
  belongs_to :auditable, polymorphic: true, optional: true

  # Device history keeps full operational values encrypted; personal changes are masked in metadata.
  encrypts :change_values

  validates :action, presence: true
  validate :validate_metadata_structure

  before_create do
    self.user_agent = Current.user_agent
    self.ip_address = Current.ip_address
  end

  # Treat absent metadata as an empty object.
  def metadata
    super || {}
  end

  # Combine metadata changes with values held in the encrypted audit cell.
  def field_changes
    (metadata['changes'] || {}).to_h { |field, change| [field, stored_change_values.fetch(field, change)] }
  end

  def field_change_pairs
    field_changes.transform_values do |change|
      case change
      when Array then change
      when Hash then change.key?('old') ? change.values_at('old', 'new') : change.values_at('from', 'to')
      else [nil, change]
      end
    end
  end

  # Scope for finding events by metadata key/value
  scope :with_metadata, lambda { |key, value|
    where('metadata @> ?', { key => value }.to_json)
  }

  def self.preload_auditable_associations(events)
    by_type = events.filter_map(&:auditable).group_by(&:class)
    ActiveRecord::Associations::Preloader.new(records: by_type[Application], associations: [:user]).call if by_type[Application]
    ActiveRecord::Associations::Preloader.new(records: by_type[Evaluation], associations: [:constituent]).call if by_type[Evaluation]
    ActiveRecord::Associations::Preloader.new(records: by_type[TrainingSession], associations: [:constituent]).call if by_type[TrainingSession]
  end

  private

  # A corrupt or undecryptable cell is logged and treated as empty, so history pages still render.
  def stored_change_values
    change_values.present? ? JSON.parse(change_values) : {}
  rescue JSON::ParserError, ActiveRecord::Encryption::Errors::Base => e
    Rails.logger.error("Event #{id}: unreadable change_values (#{e.class})")
    {}
  end

  def validate_metadata_structure
    return if metadata.is_a?(Hash)

    errors.add(:metadata, 'must be a JSON object')
  end
end
