# frozen_string_literal: true

module Users
  class Evaluator < User
    has_many :evaluations, dependent: :restrict_with_error
    has_many :assigned_constituents,
             through: :evaluations,
             source: :constituent

    def self.available
      User.where(type: ['Users::Administrator', 'Users::Evaluator'])
    end
  end
end
