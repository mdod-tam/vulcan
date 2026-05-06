# frozen_string_literal: true

module Trainers
  # Base controller for the trainers portal.
  class BaseController < ApplicationController
    include Pagy::Backend

    before_action :require_trainer

    private

    def require_trainer
      return if current_user&.assignable_trainer?

      redirect_to root_path, alert: 'You are not authorized to perform this action.'
    end
  end
end
