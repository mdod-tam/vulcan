# frozen_string_literal: true

module Admin
  class BaseController < ApplicationController
    include NotificationPreloading
    include SafeInstanceVariables

    helper_method :equipment_navigation_summary

    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_current_attributes

    private

    def recent_admin_notifications
      notifications = Notification.where(recipient: current_user).includes(:actor, :notifiable).includes(notifiable: :application)
                                  .where('created_at > ?', 7.days.ago).order(created_at: :desc).limit(3)
      preload_notification_message_dependencies(notifications)
      notifications
    end

    def equipment_navigation_summary
      @equipment_navigation_summary ||= Equipment::NavigationSummary.new
    end

    def set_current_attributes
      Current.user_agent = request.user_agent
      Current.ip_address = request.remote_ip
      Current.user = current_user
    end
  end
end
