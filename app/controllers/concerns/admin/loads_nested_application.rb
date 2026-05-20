# frozen_string_literal: true

module Admin
  module LoadsNestedApplication
    extend ActiveSupport::Concern

    private

    def load_nested_application
      @application = Application.find(params[:application_id])
    end
  end
end
