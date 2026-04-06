# frozen_string_literal: true

module Users
  class Trainer < User
    has_many :training_sessions, dependent: :restrict_with_error
    has_many :assigned_constituents,
             through: :training_sessions,
             source: :constituent

    def self.available
      User.where(type: ['Users::Administrator', 'Users::Trainer'])
    end
  end
end
