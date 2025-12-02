# frozen_string_literal: true

module Admin
  module UsersHelper
    def capability_description(capability)
      case capability
      when 'can_evaluate'
        'Can perform evaluations and submit assessment reports'
      when 'can_train'
        'Can conduct training sessions and manage training materials'
      else
        'Additional system capability'
      end
    end

    def role_description(role)
      case role
      when 'Admin'
        'Full system access and management capabilities'
      when 'Evaluator'
        'Can perform evaluations and manage assessment data'
      when 'Constituent'
        'Standard user access to system features'
      when 'Users::Vendor'
        'Vendor-specific access and management features'
      else
        'Standard system access'
      end
    end

    def user_row_classes(user)
      classes = ['hover:bg-gray-50']
      classes << 'bg-yellow-50 hover:bg-yellow-100' if user.needs_duplicate_review

      if user.guardian? && !user.dependent? # Prioritize guardian if both (edge case)
        classes << 'bg-blue-100'
      elsif user.dependent?
        classes << 'bg-green-100'
      end

      classes.join(' ')
    end

    def inverse_relationship_label(relation)
      case relation.to_s.downcase
      when 'parent' then 'child'
      when 'guardian' then 'ward'
      else 'dependent'
      end
    end
  end
end
