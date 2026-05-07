# frozen_string_literal: true

module Admin
  module VendorsHelper
    W9HistoryItem = Struct.new(:type, :record, :occurred_at)
    W9_SECURE_REQUEST_EVENT_TITLES = {
      'w9_submitted_via_secure_form' => 'Secure W9 uploaded for review',
      'w9_upload_request_revoked' => 'Secure W9 upload link revoked',
      'w9_upload_request_expired' => 'Secure W9 upload link expired'
    }.freeze

    def vendor_w9_history_items(w9_reviews:, secure_request_events:, secure_request_notifications: [])
      review_items = w9_reviews.map do |review|
        W9HistoryItem.new(:review, review, review.reviewed_at || review.created_at)
      end

      secure_request_notification_items = secure_request_notifications.map do |notification|
        W9HistoryItem.new(:secure_request_notification, notification, notification.created_at)
      end

      secure_request_items = secure_request_events.map do |event|
        W9HistoryItem.new(:secure_request_event, event, event.created_at)
      end

      (review_items + secure_request_notification_items + secure_request_items).sort_by(&:occurred_at).reverse
    end

    def vendor_w9_history_item_icon_class(item)
      if item.type == :review && item.record.status_approved?
        'bg-green-500'
      elsif item.type == :review
        'bg-red-500'
      else
        'bg-gray-500'
      end
    end

    def vendor_w9_history_item_title(item)
      case item.type
      when :review
        item.record.status.titleize
      when :secure_request_notification
        'Secure W9 upload link sent'
      when :secure_request_event
        W9_SECURE_REQUEST_EVENT_TITLES[item.record.action]
      end
    end

    def vendor_w9_history_item_actor(item)
      case item.type
      when :review
        item.record.admin.email
      when :secure_request_notification
        item.record.actor&.email || 'System'
      when :secure_request_event
        item.record.user&.email || 'Unknown user'
      end
    end

    def vendor_w9_history_item_detail(item)
      return review_rejection_detail(item.record) if item.type == :review && item.record.status_rejected?
      return vendor_w9_secure_request_notification_detail(item.record) if item.type == :secure_request_notification
      return unless item.type == :secure_request_event

      metadata = item.record.metadata.deep_stringify_keys
      recipient_email = metadata['recipient_email']
      return if recipient_email.blank?

      "Recipient: #{secure_request_masked_email(recipient_email)}"
    end

    def vendor_secure_w9_upload_requestable?(vendor)
      vendor.email.present? && (vendor.w9_status_not_submitted? || vendor.w9_status_rejected?)
    end

    private

    def vendor_w9_secure_request_notification_detail(notification)
      metadata = (notification.metadata || {}).deep_stringify_keys
      expires_at = metadata['expires_at'].presence
      return if expires_at.blank?

      "Expires: #{l(Time.zone.parse(expires_at), format: :long)}"
    rescue ArgumentError
      nil
    end

    def review_rejection_detail(review)
      return if review.rejection_reason.blank?

      "#{review.rejection_reason_code.to_s.titleize}: #{review.rejection_reason}"
    end
  end
end
