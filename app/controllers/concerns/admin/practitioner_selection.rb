# frozen_string_literal: true

module Admin
  # Resolves the practitioner an administrator picked in an assignment form.
  module PractitionerSelection
    extend ActiveSupport::Concern

    private

    # @param capability [Symbol] The capability the user must hold, such as :can_train
    # @param param_name [Symbol] The form field holding the user id
    # @return [User, nil] The assignable user, or nil for a missing, malformed or ineligible id
    def selected_practitioner(capability, param_name)
      selected_id = params[param_name].to_s
      User.assignable_for(capability).find_by(id: selected_id) if selected_id.match?(/\A[1-9]\d*\z/)
    end
  end
end
