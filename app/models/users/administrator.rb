# frozen_string_literal: true

module Users
  class Administrator < User
    def can_manage_users?
      true
    end
  end
end
