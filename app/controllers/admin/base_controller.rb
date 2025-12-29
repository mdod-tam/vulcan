# frozen_string_literal: true

module Admin
  class BaseController < ApplicationController
    include Pagy::Backend
    include SafeInstanceVariables

    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_current_attributes

    private

    def require_admin!
      return if current_user&.admin?

      redirect_to root_path, alert: t('shared.unauthorized')
    end

    def set_current_attributes
      # Always use the current_user, even in test environment
      Current.set(request, current_user)
    end
  end
end
