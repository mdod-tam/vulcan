# frozen_string_literal: true

module Users
  class Trainer < User
    has_many :training_sessions, dependent: :restrict_with_error
    has_many :assigned_constituents,
             through: :training_sessions,
             source: :constituent

    scope :available, -> {
      left_outer_joins(:role_capabilities)
        .where(
          "users.type IN (?) OR role_capabilities.capability = ?",
          ['Users::Trainer', 'Users::Administrator'],
          'can_train'
        )
    }
  end
end
