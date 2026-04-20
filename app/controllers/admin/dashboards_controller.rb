# frozen_string_literal: true

module Admin
  # Controller for the admin dashboard
  # Displays dashboard metrics, quick action buttons, and recent activity
  class DashboardsController < BaseController
    include DashboardMetricsLoading

    def index
      # Load comprehensive dashboard metrics
      @metrics = load_dashboard_metrics

      # Load recent notifications to avoid N+1 queries
      # Preload notifiable for Notification#message, actor for view display
      @recent_notifications = Notification
                              .includes(:actor, notifiable: :user)
                              .where('created_at > ?', 7.days.ago)
                              .order(created_at: :desc)
                              .limit(5)

      # Load incomplete notes assigned to current user with pagination (3 per page)
      @pagy_assigned_notes, @assigned_notes = pagy(
        ApplicationNote
          .where(assigned_to: current_user)
          .incomplete
          .includes(:admin, application: :user)
          .recent_first,
        limit: 3
      )
    end
  end
end
