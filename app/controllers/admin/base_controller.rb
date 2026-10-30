# frozen_string_literal: true

module Admin
  class BaseController < ApplicationController
    include Pagy::Backend
    include NotificationPreloading
    include SafeInstanceVariables

    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_current_attributes

    private

    def set_current_attributes
      Current.user_agent = request.user_agent
      Current.ip_address = request.remote_ip
      Current.user = current_user
    end
  end
end
