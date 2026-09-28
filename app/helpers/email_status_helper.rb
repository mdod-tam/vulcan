# frozen_string_literal: true

module EmailStatusHelper
  def delivery_status_badge(notification)
    return '' unless notification.email_tracking? || notification.local_delivery_outcome?

    badge_class = delivery_status_badge_class(notification)
    status_text = notification.delivery_status || 'Pending'

    content_tag(:span, status_text,
                class: "ml-2 inline-flex items-center px-2 py-0.5 rounded text-xs font-medium #{badge_class}")
  end

  def format_email_status(notification)
    return '' unless notification.email_tracking? || notification.local_delivery_outcome?

    html = []
    html << build_delivery_status_section(notification)
    html << build_open_information_section(notification) if notification.opened_at.present?
    html << build_manual_check_button(notification) if show_manual_check_button?(notification)

    safe_join(html)
  end

  private

  def build_delivery_status_section(notification)
    content_tag(:div, class: 'mt-2 text-sm') do
      case notification.delivery_status
      when 'error'
        build_error_message(notification)
      when 'suppressed'
        content_tag(:p, t('notification_delivery.suppressed'))
      when nil
        content_tag(:p, 'Delivery status: Pending')
      else
        build_delivered_message(notification)
      end
    end
  end

  def build_error_message(notification)
    content_tag(:p, class: 'text-red-600') do
      "Delivery failed: #{notification.email_error_message}"
    end
  end

  def build_delivered_message(notification)
    return content_tag(:p, 'Delivery status: Pending') if notification.delivered_at.blank?

    content_tag(:p, "Delivered on #{notification.delivered_at.strftime('%B %d, %Y at %I:%M %p')}")
  end

  def build_open_information_section(notification)
    open_info = []
    open_info << content_tag(:p, "Opened on #{notification.opened_at.strftime('%B %d, %Y at %I:%M %p')}")
    open_info.concat(build_client_and_location_info(notification))

    content_tag(:div, class: 'mt-1 text-sm text-blue-600') do
      safe_join(open_info)
    end
  end

  def build_client_and_location_info(notification)
    info = []
    info << build_client_info(notification)
    info << build_location_info(notification)
    info.compact
  end

  def build_client_info(notification)
    client = notification.metadata&.dig('email_details', 'Client')
    return nil if client.blank?

    content_tag(:p, "Using #{client['Name']} on #{client['Family']}")
  end

  def build_location_info(notification)
    geo = notification.metadata&.dig('email_details', 'Geo')
    return nil unless geo.present? && geo['City'].present? && geo['Region'].present?

    content_tag(:p, "From #{geo['City']}, #{geo['Region']}")
  end

  def build_manual_check_button(notification)
    content_tag(:div, class: 'mt-2') do
      button_to 'Check Status',
                check_email_status_notification_path(notification),
                method: :post,
                class: 'text-xs bg-gray-100 hover:bg-gray-200 text-gray-800 font-semibold py-1 px-2 rounded',
                form: { 'data-turbo' => true, class: 'inline' }
    end
  end

  def show_manual_check_button?(notification)
    notification.message_id.present? &&
      !notification.delivery_status.in?(%w[error suppressed]) &&
      notification.opened_at.nil?
  end
end
