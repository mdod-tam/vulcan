class FeatureFlag < ApplicationRecord
  # Store feature flags in the database for easy toggling
  validates :name, presence: true, uniqueness: true

  # Flags the generic admin screen may show and change. Email controls have their own
  # writer (EmailDelivery::ControlWriter) because turning one off cancels pending mail.
  scope :general, -> { where.not('name LIKE ? OR name LIKE ?', 'email.%', 'communications.%') }

  # Set only by EmailDelivery::ControlWriter.
  attr_accessor :email_control_write

  validate :email_control_changed_through_writer, on: :update

  # Class methods for checking flags
  class << self
    # A stored false stays false; the default applies only when no row exists.
    def enabled?(feature_name, default: false)
      flag = find_by(name: feature_name.to_s)
      flag.nil? ? default : flag.enabled
    rescue StandardError
      default
    end

    def enable!(feature_name)
      update_general_flag!(feature_name, enabled: true)
    end

    def disable!(feature_name)
      update_general_flag!(feature_name, enabled: false)
    end

    # Income proof requirement is derived from the single `vouchers_enabled`
    # flag. Income is required only when the voucher workflow is disabled.
    def income_proof_required?
      !enabled?(:vouchers_enabled)
    end

    private

    def update_general_flag!(feature_name, enabled:)
      flag = find_or_initialize_by(name: feature_name.to_s)
      if EmailDelivery.control_name?(flag.name)
        flag.errors.add(:enabled, 'communication controls change only through EmailDelivery::ControlWriter')
        raise ActiveRecord::RecordInvalid, flag
      end
      flag.update!(enabled: enabled)
    end
  end

  private

  def email_control_changed_through_writer
    return unless EmailDelivery.control_name?(name)
    return unless enabled_changed? || delivery_generation_changed?
    return if email_control_write

    errors.add(:enabled, 'email controls change only through EmailDelivery::ControlWriter')
  end
end
