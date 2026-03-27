# frozen_string_literal: true

module Users
  class Evaluator < User
    has_many :evaluations, dependent: :restrict_with_error
    has_many :assigned_constituents,
             through: :evaluations,
             source: :constituent

    scope :available, -> {
      left_outer_joins(:role_capabilities)
        .where(
          "users.type IN (?) OR role_capabilities.capability = ?",
          ['Users::Evaluator', 'Users::Administrator'],
          'can_evaluate'
        )
    }
  end
end
