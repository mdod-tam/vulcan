# frozen_string_literal: true

class DeliveryStatusPresenter
  attr_reader :record, :attempt, :locale

  def initialize(record, attempt: nil, locale: I18n.locale)
    @record = record
    @attempt = attempt
    @locale = locale
  end

  def label = text("statuses.#{status}")
  def text(key, **) = I18n.t("delivery_visibility.#{key}", locale: locale, **)

  def details_label
    reference = text("records.#{record.model_name.i18n_key}", id: record.id)
    reference = text('attempt_for', id: attempt.id, record: reference) if attempt && record != attempt
    text('details_for', record: reference, channel: text("channels.#{channel}", default: channel), status: label)
  end

  def status
    return local_status || channel_status unless attempt

    email_status
  end

  def email_status
    return 'complained' if attempt.complained_at
    return 'bounced' if attempt.bounced_at
    return 'delivered' if attempt.delivered_at
    return 'failed' if attempt.state == 'failed'
    return 'delayed' if attempt.delayed_at || (attempt.accepted_at && attempt.attempted_at < 24.hours.ago)
    return 'accepted' if attempt.accepted_at

    'unknown'
  end

  def channel
    return 'email' if attempt
    return record.recipient_channel if record.respond_to?(:recipient_channel)

    actual = metadata['actual_delivery_channel'].presence
    return actual if actual && actual != 'none'

    metadata['requested_recipient_channel'] || metadata['recipient_channel'] || metadata['requested_channel'] ||
      metadata['channel'] || metadata['actual_delivery_channel'] || 'email'
  end

  def description
    return text('configuration_error') if !attempt && metadata.dig('delivery_error', 'reason').present?
    return text("reasons.#{reason}", default: text('reasons.suppressed')) if status == 'suppressed'
    return text('never_tracked') if status == 'unknown' && !attempt

    text("descriptions.#{status}")
  end

  def masked_destination
    address = attempt&.destination
    address ||= record.recipient_email if record.respond_to?(:recipient_email)
    address ||= record.provider_email if record.respond_to?(:provider_email)
    return nil if address.blank?

    local, domain = address.split('@', 2)
    return nil if local.blank? || domain.blank?

    "#{local.first}***@#{domain}"
  end

  def owner_label
    return unless attempt&.delivery_owner

    attempt.delivery_owner.full_name
  end

  def requested_at = record.respond_to?(:sent_at) ? record.sent_at : record.created_at
  def sent_at = attempt&.accepted_at
  def attempted_at = attempt&.attempted_at
  def last_update = attempt&.feedback_at
  def last_check = attempt&.last_checked_at
  def stale? = attempt&.tracking_stale?
  def opened_at = attempt&.opened_at
  def bounce_category = attempt&.bounce_category && text("bounce_categories.#{attempt.bounce_category}", default: text('bounce_categories.Other'))

  def badge_class
    return 'bg-red-100 text-red-800' if %w[bounced complained failed].include?(status)
    return 'bg-green-100 text-green-800' if %w[delivered letter_printed].include?(status)
    return 'bg-amber-100 text-amber-900' if %w[delayed suppressed].include?(status)

    'bg-gray-100 text-gray-800'
  end

  private

  def notification
    record.is_a?(Notification) ? record : (record.delivery_notification if record.respond_to?(:delivery_notification))
  end

  def metadata = notification&.metadata.to_h
  def reason = metadata.dig('delivery_suppressed', 'reason')

  def local_status
    return 'suppressed' if notification&.suppressed_delivery_status?
    return 'failed' if notification&.error_delivery_status? && !attempt
    return 'queued' if notification&.queued_delivery_status? && !attempt && channel == 'email'

    nil
  end

  def letter_status
    item = record.print_queue_items.max_by(&:id)
    return 'unknown' unless item

    { printed: 'letter_printed', released: 'letter_released', canceled: 'letter_canceled',
      configuration_error: 'failed', blocked: 'letter_blocked', queued: 'queued' }.fetch(item.display_delivery_state)
  end

  def channel_status
    return letter_status if channel == 'letter' && record.respond_to?(:print_queue_items)
    return 'sms_submitted' if channel == 'sms' && notification&.submitted_delivery_status?
    return 'docuseal' if channel == 'docuseal'

    local_status || 'unknown'
  end
end
