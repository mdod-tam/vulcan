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
      # Preload notifiable for Notification#message, but not notifiable.user
      @recent_notifications = Notification
                              .includes(:actor, :notifiable)
                              .where('created_at > ?', 7.days.ago)
                              .order(created_at: :desc)
                              .limit(5)
                              .map { |n| NotificationDecorator.new(n) }
    end
  end
end
