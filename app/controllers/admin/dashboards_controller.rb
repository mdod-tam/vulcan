# frozen_string_literal: true

module Admin
  # Admin dashboard: metrics, recent notifications, and the current admin's open notes.
  class DashboardsController < BaseController
    include DashboardMetricsLoading

    def show
      @metrics = load_dashboard_metrics

      # Preload notifiable for Notification#message and actor for the view.
      @recent_notifications = Notification
                              .includes(:actor, :notifiable)
                              .includes(notifiable: :application)
                              .where('created_at > ?', 7.days.ago)
                              .order(created_at: :desc)
                              .limit(3)

      preload_notification_message_dependencies(@recent_notifications)

      # Incomplete notes assigned to the current admin, three per page.
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
