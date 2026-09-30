# frozen_string_literal: true

module EmailStatusHelper
  def delivery_visibility(record, locale: I18n.locale)
    attempts = record.email_delivery_attempts.sort_by(&:id)
    attempts = [nil] if attempts.empty?
    attempts += [nil] if attempts.compact.any? && record.is_a?(Notification) && record.local_delivery_outcome?
    safe_join(attempts.map do |attempt|
      render 'shared/delivery/status', presenter: DeliveryStatusPresenter.new(record, attempt: attempt, locale: locale)
    end)
  end

  def delivery_status_badge(notification)
    presenter = DeliveryStatusPresenter.new(notification, attempt: notification.email_delivery_attempts.max_by(&:id))
    content_tag(:span, presenter.label, class: "inline-flex rounded px-2 py-1 text-xs #{presenter.badge_class}")
  end

  def delivery_status_text(notification, locale: I18n.locale)
    DeliveryStatusPresenter.new(notification, attempt: notification.email_delivery_attempts.max_by(&:id), locale: locale).label
  end

  def format_email_status(notification) = delivery_visibility(notification)

  def notification_viewer_locale
    current_user.locale.presence || I18n.locale
  end
end
