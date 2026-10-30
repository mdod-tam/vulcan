# frozen_string_literal: true

module Admin
  # Loads the application a member action changes. An unknown id returns to the list.
  module LoadsApplication
    extend ActiveSupport::Concern

    included do
      before_action :set_application
    end

    private

    def set_application
      @application = Application.find(params.expect(:id))
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_applications_path, alert: t('alerts.app_not_found')
    end
  end
end
