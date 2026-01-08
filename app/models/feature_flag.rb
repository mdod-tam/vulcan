class FeatureFlag < ApplicationRecord
  # Store feature flags in the database for easy toggling
  validates :name, presence: true, uniqueness: true
  
  # Class methods for checking flags
  class << self
    def enabled?(feature_name, default: false)
      find_by(name: feature_name.to_s)&.enabled || default
    rescue StandardError
      default
    end

    def enable!(feature_name)
      find_or_initialize_by(name: feature_name.to_s).update!(enabled: true)
    end

    def disable!(feature_name)
      find_or_initialize_by(name: feature_name.to_s).update!(enabled: false)
    end
  end
end
