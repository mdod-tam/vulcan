# frozen_string_literal: true

module SecureRequestFormsHelper
  def secure_request_masked_contact(secure_request_form)
    case secure_request_form.recipient_channel
    when 'email'
      secure_request_masked_email(secure_request_form.recipient_email)
    when 'sms'
      secure_request_masked_phone(secure_request_form.recipient_phone)
    when 'letter'
      t('admin.applications.secure_request_forms.contact.letter')
    else
      t('admin.applications.secure_request_forms.contact.unknown')
    end
  end

  def secure_request_channel_label(secure_request_form)
    t("admin.applications.secure_request_forms.channels.#{secure_request_form.recipient_channel}")
  end

  def secure_request_channel_label_for(channel)
    return t('admin.applications.secure_request_forms.contact.unknown') if channel.blank?

    t("admin.applications.secure_request_forms.channels.#{channel}",
      default: t('admin.applications.secure_request_forms.contact.unknown'))
  end

  def secure_request_status_label(secure_request_form)
    t("admin.applications.secure_request_forms.statuses.#{secure_request_form.display_status}")
  end

  def secure_request_summary_accessible_label(summary)
    label = t('admin.applications.secure_request_forms.summary.label')

    segments = [
      label,
      secure_request_summary_sent_text(summary),
      secure_request_summary_expiration_text(summary)
    ].compact
    "#{segments.join('. ')}."
  end

  def secure_request_summary_sent_text(summary)
    return if summary[:last_sent_at].blank?

    t('admin.applications.secure_request_forms.summary.last_sent',
      time: secure_request_summary_date(summary.fetch(:last_sent_at)))
  end

  def secure_request_summary_expiration_text(summary)
    case summary[:summary_status]&.to_sym
    when :active
      return if summary[:nearest_expiration_at].blank?

      t('admin.applications.secure_request_forms.summary.nearest_expiration',
        time: secure_request_summary_date(summary.fetch(:nearest_expiration_at)))
    when :expired
      t('admin.applications.secure_request_forms.summary.expired')
    when :revoked
      t('admin.applications.secure_request_forms.summary.revoked')
    end
  end

  def secure_request_masked_email(email)
    local, domain = email.to_s.split('@', 2)
    return t('admin.applications.secure_request_forms.contact.unknown') if local.blank? || domain.blank?

    "#{local.first}***@#{domain}"
  end

  def secure_request_masked_phone(phone)
    digits = phone.to_s.gsub(/\D/, '')
    return t('admin.applications.secure_request_forms.contact.unknown') if digits.blank?

    "•••-•••-#{digits.last(4)}"
  end

  def secure_request_notification_detail(notification, application:)
    metadata = notification.metadata.is_a?(Hash) ? notification.metadata.stringify_keys : {}

    case notification.action
    when 'provider_info_requested'
      secure_provider_info_notification_detail(notification, metadata)
    when 'proof_resubmission_requested'
      secure_proof_resubmission_notification_detail(notification, metadata)
    when 'cert_upload_requested'
      secure_cert_upload_notification_detail(metadata, application)
    end
  end

  def secure_request_lifecycle_event_detail(event, application:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata.stringify_keys : {}
    reason_text = secure_request_revocation_reason_text(metadata)

    case event.action
    when 'provider_info_request_revoked'
      recipient_name = metadata['recipient_name'].presence || 'the recipient'
      channel = secure_request_channel_label_for(metadata['recipient_channel'])
      "Secure provider information request revoked for #{recipient_name} via #{channel}#{reason_text}"
    when 'proof_resubmission_request_revoked'
      recipient_name = metadata['recipient_name'].presence || 'the recipient'
      channel = secure_request_channel_label_for(metadata['recipient_channel'])
      proof_name = metadata['proof_type'].to_s.humanize.presence || 'proof'
      "Secure #{proof_name.downcase} upload link revoked for #{recipient_name} via #{channel}#{reason_text}"
    when 'proof_resubmission_request_expired'
      recipient_name = metadata['recipient_name'].presence || 'the recipient'
      channel = secure_request_channel_label_for(metadata['recipient_channel'])
      proof_name = metadata['proof_type'].to_s.humanize.presence || 'proof'
      "Secure #{proof_name.downcase} upload link expired for #{recipient_name} via #{channel}"
    when 'cert_upload_request_revoked'
      "Secure certification upload link revoked for #{secure_request_cert_upload_target(metadata, application)}#{reason_text}"
    when 'cert_upload_request_expired'
      "Secure certification upload link expired for #{secure_request_cert_upload_target(metadata, application)}"
    when 'proof_submitted_via_secure_form'
      proof_name = metadata['proof_type'].to_s.humanize.presence || 'proof'
      "Secure #{proof_name.downcase} proof uploaded for review"
    when 'cert_submitted_via_secure_form'
      "Secure certification uploaded for #{secure_request_cert_upload_target(metadata, application)}"
    end
  end

  alias secure_request_revocation_event_detail secure_request_lifecycle_event_detail

  private

  def secure_request_summary_date(time)
    l(time.to_date, format: :month_day)
  end

  def secure_request_notification_expires_text(metadata)
    expires_at = metadata['expires_at']
    return '' if expires_at.blank?

    " (expires #{l(Time.zone.parse(expires_at), format: :short)})"
  rescue ArgumentError, TypeError
    ''
  end

  def secure_provider_info_notification_detail(notification, metadata)
    recipient_name = notification.recipient&.full_name || 'Unknown recipient'
    channel = secure_request_recipient_channel_label(metadata)
    expires_text = secure_request_notification_expires_text(metadata)

    "Secure provider information request sent to #{recipient_name} via #{channel}#{expires_text}"
  end

  def secure_proof_resubmission_notification_detail(notification, metadata)
    recipient_name = notification.recipient&.full_name || 'Unknown recipient'
    channel = secure_request_recipient_channel_label(metadata)
    proof_name = metadata['proof_type'].to_s.humanize.presence || 'proof'
    expires_text = secure_request_notification_expires_text(metadata)

    "Secure #{proof_name.downcase} upload link sent to #{recipient_name} via #{channel}#{expires_text}"
  end

  def secure_cert_upload_notification_detail(metadata, application)
    channel = secure_request_channel_label_for(metadata['requested_channel'] || metadata['channel'])
    target = secure_request_cert_upload_target(metadata, application)
    expires_text = secure_request_notification_expires_text(metadata)

    "Secure certification upload link sent to #{target} via #{channel}#{expires_text}"
  end

  def secure_request_recipient_channel_label(metadata)
    secure_request_channel_label_for(
      metadata['requested_recipient_channel'] || metadata['recipient_channel'] || metadata['channel']
    )
  end

  def secure_request_cert_upload_target(metadata, application)
    provider_name = metadata['provider_name'].presence || application.medical_provider_name.presence
    provider_email = metadata['provider_email'].presence || application.medical_provider_email.presence
    masked_email = provider_email.present? ? secure_request_masked_email(provider_email) : nil

    if provider_name.present? && masked_email.present?
      "#{provider_name} (#{masked_email})"
    elsif provider_name.present?
      provider_name
    elsif masked_email.present?
      masked_email
    else
      'the provider'
    end
  end

  def secure_request_revocation_reason_text(metadata)
    case metadata['reason'].to_s
    when 'replacement_request'
      ' before sending a replacement link'
    when 'document_signing_request_sent'
      ' because a DocuSeal request was sent'
    else
      ''
    end
  end
end
