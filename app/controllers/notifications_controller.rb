# frozen_string_literal: true

# In-app notifications: list, mark as read, and (admins only) refresh email delivery status.
class NotificationsController < ApplicationController
  include Pagy::Backend
  include NotificationPreloading

  before_action :authenticate_user!
  before_action :authorize_delivery_refresh, only: :check_email_status
  before_action :set_notification, only: %i[check_email_status mark_as_read]

  def index
    # Admins see all notifications by default; everyone else sees their own.
    scope = params[:scope] || (current_user.admin? ? 'all' : 'mine')

    notifications = if scope == 'all' && current_user.admin?
                      # Preload notifiable for Notification#message and actor for the view.
                      Notification.includes(:notifiable, :actor).order(created_at: :desc)
                    else
                      current_user.received_notifications.includes(:notifiable, :actor).order(created_at: :desc)
                    end

    @current_scope = scope
    @pagy, @notifications = pagy(notifications, items: 20)
    preload_notification_message_dependencies(@notifications)
  end

  def mark_as_read
    @notification.mark_as_read!

    respond_to do |format|
      format.html do
        redirect_back_or_to notifications_path
      end
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace("notification_#{@notification.id}",
                                                  partial: 'notifications/notification',
                                                  locals: { notification: @notification })
      end
    end
  end

  def check_email_status
    tracking = @notification.email_tracking?
    UpdateEmailStatusJob.perform_later(@notification.id) if tracking

    flash_message = tracking ? 'Checking email status. This may take a moment.' : 'Cannot check status for this notification.'

    respond_to do |format|
      format.html do
        flash[tracking ? :notice : :alert] = flash_message
        redirect_back_or_to root_path
      end
      format.turbo_stream do
        flash.now[tracking ? :notice : :alert] = flash_message
        render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash')
      end
    end
  end

  private

  def authorize_delivery_refresh
    head :forbidden unless current_user.admin?
  end

  def set_notification
    scope = current_user.admin? ? Notification.all : current_user.received_notifications
    @notification = scope.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    respond_to do |format|
      format.html do
        flash[:alert] = 'Notification not found.'
        redirect_back_or_to root_path
      end
      format.turbo_stream do
        flash.now[:alert] = 'Notification not found.'
        render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash')
      end
    end
  end
end
