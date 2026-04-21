# frozen_string_literal: true

module Users
  class Evaluator < User
    has_many :evaluations, dependent: :restrict_with_error
    has_many :assigned_constituents,
             through: :evaluations,
             source: :constituent

    # Valid assignable evaluators for practitioner assignment UI.
    # Includes dedicated Evaluator users plus admins who explicitly hold the
    # can_evaluate capability. Explicitly inactive/suspended users are excluded;
    # legacy rows with status: NULL are treated as assignable because the
    # User status enum only backfilled a default on new records.
    def self.available
      inactive_codes = User.statuses.values_at(:inactive, :suspended)

      User.where('users.status IS NULL OR users.status NOT IN (?)', inactive_codes)
          .where(
            "users.type = :evaluator_type
             OR (users.type = :admin_type AND EXISTS (
               SELECT 1 FROM role_capabilities rc
               WHERE rc.user_id = users.id AND rc.capability = 'can_evaluate'
             ))",
            evaluator_type: 'Users::Evaluator',
            admin_type: 'Users::Administrator'
          )
    end
  end
end
