# frozen_string_literal: true

module SecureRequestFormsHelper
  # Rows repeat the same buttons, so each gets a name that says which link it acts on.
  def secure_link_row_action_label(action, secure_form, recipient:)
    t('admin.secure_link_row_action', action: action, recipient: recipient, sent_at: l(secure_form.sent_at, format: :short))
  end

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

  def secure_request_row_status(form)
    letter = form.print_queue_items.max_by(&:id) if form.recipient_channel_letter?
    request_status = if letter&.downloaded_copy_to_resolve?
                       tag.span('Request closed. Do not mail this copy.', class: 'text-danger-800')
                     elsif letter.nil?
                       tag.span(t("admin.applications.secure_request_forms.statuses.#{form.display_status}"))
                     end
    safe_join([request_status, delivery_visibility(form)].compact)
  end

  # Stable IDs distinguish people even when names, relationships and contacts collide.
  def secure_request_recipient_label(recipient, application: nil, role: nil, relationship_type: nil)
    role = role.to_s.presence
    role ||= 'constituent' if application.present? && recipient.id == application.user_id

    qualifier =
      case role
      when 'guardian'
        guardian = t('admin.applications.secure_request_forms.roles.guardian')
        relationship_type.present? ? "#{guardian} — #{relationship_type}" : guardian
      when 'constituent'
        t('admin.applications.secure_request_forms.roles.applicant')
      end

    [recipient.full_name, ("(#{qualifier})" if qualifier), "(ID: #{recipient.id})"].compact.join(' ')
  end

  # Guardian provenance supplies the role label. Missing provenance stays explicitly unknown.
  def secure_request_delivery_owner_label(owner, delivery_source: nil)
    if delivery_source.blank?
      return t('admin.applications.secure_request_forms.delivery_owner.source_unknown',
               owner: secure_request_recipient_label(owner))
    end

    guardian_source = %w[managing_guardian guardian_relationship].include?(delivery_source.to_s)
    secure_request_recipient_label(owner, role: guardian_source ? 'guardian' : nil)
  end

  # Persisted qualifiers match the chooser, e.g. "Jane Smith (Guardian — Parent)".
  def secure_request_issued_recipient_label(secure_request_form)
    secure_request_recipient_label(secure_request_form.recipient,
                                   role: secure_request_form.recipient_role,
                                   relationship_type: secure_request_form.recipient_relationship_type)
  end

  # "Originally" identifies the historical owner. Resends resolve the current owner and contact.
  def secure_request_original_delivery_owner_text(secure_request_form)
    ownership_unknown = t('admin.applications.secure_request_forms.table.delivery_ownership_unknown')
    return ownership_unknown unless secure_request_form.delivery_provenance?

    owner = secure_request_form.delivery_owner
    return if owner.nil? || secure_request_form.delivery_owner_id == secure_request_form.recipient_id

    t('admin.applications.secure_request_forms.table.originally_delivered_to',
      owner: secure_request_delivery_owner_label(owner, delivery_source: secure_request_form.delivery_source))
  end

  def secure_request_option_selectable?(option)
    option[:eligible] && option[:candidate]&.deliverable_channels&.any?
  end

  def secure_request_option_unavailable_text(option)
    reason = if !option[:eligible]
               'ineligible'
             elsif option[:candidate]&.owner_ineligible_channels&.any?
               'owner_ineligible'
             else
               'no_route'
             end
    t("admin.applications.secure_request_forms.panel.#{reason}")
  end

  def secure_request_channel_options(candidate)
    candidate.deliverable_channels.map do |channel|
      destination = secure_request_candidate_destination_text(candidate, channel: channel)
      ["#{secure_request_channel_label_for(channel)} — #{destination}", channel.to_s]
    end
  end

  def secure_request_candidate_destination_text(candidate, channel: candidate&.channel)
    return if candidate.nil?

    channel = channel&.to_sym || candidate.deliverable_channels.first
    return if channel.nil?

    destination =
      case channel
      when :email then secure_request_masked_email(candidate.email)
      when :sms then secure_request_masked_phone(candidate.phone)
      when :letter then secure_request_letter_destination(candidate.address_owner)
      end
    return if destination.blank?

    owner = candidate.delivery_owner_for(channel)
    if owner.present? && owner.id != candidate.recipient.id
      t('admin.applications.secure_request_forms.panel.destination_via',
        owner: secure_request_delivery_owner_label(owner, delivery_source: 'managing_guardian'),
        destination: destination)
    else
      t('admin.applications.secure_request_forms.panel.destination', destination: destination)
    end
  end

  # The admin page already shows full addresses, so this stays unmasked ("123 Main St, Baltimore, MD 21201").
  def secure_request_letter_destination(address_owner)
    return if address_owner.nil?

    city_state = [address_owner.city, address_owner.state].compact_blank.join(', ')
    city_state_zip = [city_state.presence, address_owner.zip_code].compact.join(' ')
    [address_owner.physical_address_1, city_state_zip].compact_blank.join(', ').presence
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
    when :paper
      'Paper request open'
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

  def secure_request_notification_detail(notification, application:, delivery_owners_by_id:)
    metadata = notification.metadata.is_a?(Hash) ? notification.metadata.stringify_keys : {}

    case notification.action
    when 'provider_info_requested', 'proof_resubmission_requested'
      secure_user_request_notification_detail(notification, metadata, delivery_owners_by_id:)
    when 'cert_upload_requested'
      secure_cert_upload_notification_detail(metadata, application)
    end
  end

  def secure_request_notification_for_postal_mail?(notification)
    metadata = notification.metadata
    metadata.is_a?(Hash) && secure_request_notification_channel(metadata) == 'letter'
  end

  def secure_request_lifecycle_event_detail(event, application:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata.stringify_keys : {}
    reason_text = secure_request_revocation_reason_text(metadata)

    case event.action
    when 'provider_info_request_revoked'
      recipient_name = metadata['recipient_name'].presence || 'the recipient'
      channel = secure_request_channel_label_for(metadata['recipient_channel'])
      "Secure provider information request revoked for #{recipient_name} via #{channel}#{reason_text}"
    when 'proof_resubmission_request_revoked', 'proof_resubmission_request_expired'
      recipient_name = metadata['recipient_name'].presence || 'the recipient'
      proof_name = metadata['proof_type'].to_s.humanize.downcase.presence || 'proof'
      change = event.action.end_with?('_revoked') ? 'revoked' : 'expired'
      paper_revocation = change == 'revoked' && metadata['recipient_channel'] == 'letter'
      return "Paper #{proof_name} request revoked for #{recipient_name}#{reason_text}" if paper_revocation

      channel = secure_request_channel_label_for(metadata['recipient_channel'])
      "Secure #{proof_name} upload link #{change} for #{recipient_name} via #{channel}#{reason_text}"
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

  def secure_user_request_notification_detail(notification, metadata, delivery_owners_by_id:)
    recipient_name = notification.recipient&.full_name || 'Unknown recipient'
    channel = secure_request_notification_channel(metadata)
    owner_text = secure_request_delivery_owner_text(notification, metadata, delivery_owners_by_id:)
    proof_context = secure_proof_resubmission_request_context(notification, metadata, metadata['proof_type']) if notification.action == 'proof_resubmission_requested'

    return ["Paper response requested from #{recipient_name}#{owner_text}.", proof_context].compact.join(' ') if channel == 'letter'

    expires_text = secure_request_notification_expires_text(metadata)
    message = proof_context ? "#{proof_context}; secure upload link" : 'Secure provider information request'
    "#{message} sent to #{recipient_name} via #{secure_request_channel_label_for(channel)}#{owner_text}#{expires_text}"
  end

  # Name the actual owner so the audit does not imply use of the logical recipient's contact.
  def secure_request_delivery_owner_text(notification, metadata, delivery_owners_by_id:)
    owner_id = metadata['delivery_owner_id']
    return '' if owner_id.blank? || owner_id.to_i == notification.recipient_id

    owner = delivery_owners_by_id.to_h[owner_id.to_i]
    return '' if owner.nil?

    owner_verb = secure_request_notification_channel(metadata) == 'letter' ? 'addressed to' : 'delivered to'
    " (#{owner_verb} #{secure_request_delivery_owner_label(owner, delivery_source: metadata['delivery_source'])})"
  end

  def secure_proof_resubmission_request_context(notification, metadata, proof_type)
    proof_type = proof_type.to_s
    application = notification.notifiable if notification.notifiable.is_a?(Application)

    if notification.proof_resubmission_rejected?
      return ProofNotificationCopy.not_provided_text(proof_type) if metadata['rejection_reason_code'] == 'none_provided'

      reason = metadata['rejection_reason'].presence || latest_secure_proof_rejection_reason(application, proof_type)
      return ProofNotificationCopy.rejected_text(proof_type, reason)
    end

    ProofNotificationCopy.requested_text(proof_type)
  end

  def latest_secure_proof_rejection_reason(application, proof_type)
    return if application.blank? || proof_type.blank?

    application.proof_reviews
               .where(proof_type: proof_type, status: :rejected)
               .order(updated_at: :desc, created_at: :desc)
               .pick(:rejection_reason)
  end

  def secure_cert_upload_notification_detail(metadata, application)
    channel = secure_request_channel_label_for(metadata['requested_channel'] || metadata['channel'])
    target = secure_request_cert_upload_target(metadata, application)
    expires_text = secure_request_notification_expires_text(metadata)

    "Secure certification upload link sent to #{target} via #{channel}#{expires_text}"
  end

  def secure_request_notification_channel(metadata)
    metadata['requested_recipient_channel'] || metadata['recipient_channel'] || metadata['channel']
  end

  def secure_request_cert_upload_target(metadata, application)
    provider_name = metadata['provider_name'].presence || application.certifying_professional_name.presence
    provider_email = metadata['provider_email'].presence || application.certifying_professional_email.presence
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
    when 'fulfilled_by_staff'
      ' after staff recorded the response'
    when 'replacement_request'
      metadata['recipient_channel'] == 'letter' ? ' before issuing a replacement letter' : ' before sending a replacement link'
    when 'document_signing_request_sent'
      ' because a DocuSeal request was sent'
    else
      ''
    end
  end
end
