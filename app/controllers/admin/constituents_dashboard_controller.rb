# frozen_string_literal: true

module Admin
  class ConstituentsDashboardController < ApplicationController
    before_action :require_admin!

    def index
      @constituents = Users::Constituent.includes(:applications, :evaluations, :training_sessions).order(:last_name)
      @constituents = @constituents.where('last_name LIKE ?', "%#{params[:search]}%") if params[:search].present
    end

    def show
      @constituent = Users::Constituent.find(params.expect(:id))
      @equipment_history = @constituent.equipment_history
    end
  end
end
