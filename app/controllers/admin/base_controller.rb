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

    # A page parameter that is not a positive integer shows the first page. A pagination error about anything else
    # is a fault, so it propagates. A page past the end is already handled by Pagy's overflow setting.
    def paginate_or_first_page(scope, **)
      pagy(scope, **)
    rescue Pagy::VariableError => e
      raise unless e.variable == :page

      pagy(scope, **, page: 1)
    end
  end
end
