# frozen_string_literal: true

module ConstituentPortal
  class TrainingSessionsController < ApplicationController
    include ViewerLocale

    around_action :with_viewer_locale

    before_action :authenticate_user!
    before_action :require_constituent!

    def index
      @training_sessions = authorized_sessions.includes(:trainer, :product_trained_on, application: :user)
                                              .order(completed_at: :desc, id: :desc)
    end

    def show
      @training_session = authorized_sessions.includes(:trainer, :product_trained_on, application: :user).find(params.expect(:id))
    end

    private

    def authorized_sessions
      TrainingSession.completed_sessions.where(application: Application.accessible_by(current_user))
    end
  end
end
