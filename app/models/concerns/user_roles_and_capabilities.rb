# frozen_string_literal: true

# Concern for handling user roles and capabilities.
module UserRolesAndCapabilities
  extend ActiveSupport::Concern

  VALID_ROLES = %w[admin constituent evaluator vendor trainer].freeze

  # The staff capability policy. A role provides some capabilities and may be granted others; every other role has
  # neither. Keys are STI class basenames, so Users::Trainer and the older Trainer spelling resolve alike.
  CAPABILITY_MATRIX = {
    'Administrator' => { provides: %w[can_train can_evaluate].freeze, grantable: [].freeze }.freeze,
    'Evaluator' => { provides: %w[can_evaluate].freeze, grantable: %w[can_train].freeze }.freeze,
    'Trainer' => { provides: %w[can_train].freeze, grantable: %w[can_evaluate].freeze }.freeze
  }.freeze

  included do
    has_many :role_capabilities, dependent: :destroy

    scope :admins, -> { where(type: 'Users::Administrator') }
    scope :vendors, -> { where(type: 'Users::Vendor') }
  end

  class_methods do
    # Persisted staff who can take work needing the capability now: login-active, not merged, and holding it through
    # their role or an explicit grant their role allows. Pickers and recovery queries share this relation.
    def assignable_for(capability)
      capability = capability.to_s
      providers = roles_with(:provides, capability)
      grantees = roles_with(:grantable, capability)
      granted = RoleCapability.where(capability: capability).select(:user_id)

      holders = where(type: sti_types(providers)).or(where(type: sti_types(grantees), id: granted))
      holders.where(merged_into_user_id: nil)
             .where('users.status IS NULL OR users.status NOT IN (?)', User.statuses.values_at(:inactive, :suspended))
    end

    private

    def roles_with(kind, capability)
      CAPABILITY_MATRIX.select { |_role, policy| policy[kind].include?(capability) }.keys
    end

    def sti_types(roles)
      roles.flat_map { |role| ["Users::#{role}", role] }
    end
  end

  def admin?
    is_a?(Users::Administrator)
  end

  VALID_ROLES.each do |role|
    next if role == 'admin' # admin? is handled separately

    define_method "#{role}?" do
      # Check for both namespaced and non-namespaced type values
      self.class.name == "Users::#{role.classify}" ||
        type == "Users::#{role.classify}" ||
        type == role.classify
    end
  end

  def role_type
    type.to_s.demodulize.presence || 'Unknown'
  end

  def role_provided_capabilities
    CAPABILITY_MATRIX.dig(type.to_s.demodulize, :provides) || []
  end

  def grantable_capabilities
    CAPABILITY_MATRIX.dig(type.to_s.demodulize, :grantable) || []
  end

  # A stored grant counts only while the role allows it, so a forbidden or redundant row confers nothing.
  # Reads the loaded association when present, so a preloaded page costs no query per row.
  def explicit_grant?(capability)
    capability = capability.to_s
    return false unless grantable_capabilities.include?(capability)
    return role_capabilities.any? { |grant| grant.capability == capability } if role_capabilities.loaded?

    role_capabilities.exists?(capability: capability)
  end

  def effective_capability?(capability)
    role_provided_capabilities.include?(capability.to_s) || explicit_grant?(capability)
  end

  def effective_capabilities
    RoleCapability::CAPABILITIES.select { |capability| effective_capability?(capability) }
  end

  def can_evaluate?
    effective_capability?('can_evaluate')
  end

  def can_train?
    effective_capability?('can_train')
  end

  def assignable_evaluator?
    persisted? && public_login_active? && can_evaluate?
  end

  def assignable_trainer?
    persisted? && public_login_active? && can_train?
  end
end
