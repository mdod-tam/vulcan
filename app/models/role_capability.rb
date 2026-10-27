# frozen_string_literal: true

class RoleCapability < ApplicationRecord
  belongs_to :user

  CAPABILITIES = %w[can_train can_evaluate].freeze

  validates :capability, presence: true, inclusion: { in: CAPABILITIES }
  validates :user_id, uniqueness: { scope: :capability }
  validate :role_allows_capability, if: -> { user && capability.in?(CAPABILITIES) }

  private

  # Only the grants the role matrix lists are stored; a capability the role already provides is not a grant.
  def role_allows_capability
    return if user.grantable_capabilities.include?(capability)

    errors.add(:capability, "cannot be granted to a #{user.role_type.downcase}")
  end
end
