# frozen_string_literal: true

# NotificationsController handles actions related to email notifications.
class NotificationsController < ApplicationController
  include Pagy::Backend

  before_action :authenticate_user!
  before_action :set_notification, only: %i[check_email_status mark_as_read]

  def index
    # Default to showing "mine" for regular users, "all" for admins
    scope = params[:scope] || (current_user.admin? ? 'all' : 'mine')

    # Get notifications based on scope
    notifications = if scope == 'all' && current_user.admin?
                      # Preload notifiable for Notification#message, actor for view display
                      Notification.includes(:notifiable, :actor).order(created_at: :desc)
                    else
                      current_user.received_notifications.includes(:notifiable, :actor).order(created_at: :desc)
                    end

    @current_scope = scope
    @pagy, @notifications = pagy(notifications, items: 20)
  end

  def mark_as_read
    @notification.mark_as_read!

    respond_to do |format|
      format.html do
        redirect_back(fallback_location: notifications_path)
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
    render_partials = [turbo_stream.replace('flash', partial: 'shared/flash')]
    if tracking
      render_partials << turbo_stream.append("notification_#{@notification.id}",
                                             partial: 'notifications/checking_status')
    end

    respond_to do |format|
      format.html do
        flash[tracking ? :notice : :alert] = flash_message
        redirect_back(fallback_location: root_path)
      end
      format.turbo_stream do
        flash.now[tracking ? :notice : :alert] = flash_message
        render turbo_stream: render_partials
      end
    end
  end

  private

  def set_notification
    @notification = Notification.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    respond_to do |format|
      format.html do
        flash[:alert] = 'Notification not found.'
        redirect_back(fallback_location: root_path)
      end
      format.turbo_stream do
        flash.now[:alert] = 'Notification not found.'
        render turbo_stream: turbo_stream.replace('flash', partial: 'shared/flash')
      end
    end
  end
end
