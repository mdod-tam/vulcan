# frozen_string_literal: true

class TrainingSessionNotificationsMailer < ApplicationMailer
  include Rails.application.routes.url_helpers
  include Mailers::SharedPartialHelpers

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  # The assignment actions take .with(recipient:, assignment:, operation_id:). The recipient is the person the
  # notice was written for, never whoever holds the assignment when the job runs.
  def trainer_assigned
    deliver_trainer_notice('training_session_notifications_trainer_assigned',
                           fallback_title: 'New Training Assignment',
                           message: 'Please contact the constituent to schedule this training session.')
  end

  def trainer_reassigned
    deliver_trainer_notice('training_session_notifications_trainer_reassigned',
                           fallback_title: 'Training Reassigned',
                           message: 'Any scheduled appointment is unchanged. Please confirm the arrangements with the constituent.')
  end

  # Tells the constituent that the trainer changed and that an existing appointment still stands.
  def trainer_changed
    training_session = params[:assignment]
    constituent = params[:recipient]
    @application = training_session.application
    superseded = superseded_assignment_delivery(training_session, operation_id: params[:operation_id])
    return superseded if superseded

    locale = resolve_template_locale(recipient: constituent)
    @notification_locale = locale
    template_name = 'training_session_notifications_trainer_changed'
    text_template = find_text_template(template_name, locale: locale)
    trainer = training_session.trainer
    variables = {
      constituent_full_name: constituent.full_name,
      trainer_full_name: trainer.full_name,
      trainer_email: trainer.email,
      trainer_phone_formatted: trainer.phone.presence || localized_not_specified(locale),
      training_session_schedule_text: training_session_schedule_text(training_session),
      scheduled_location: notification_location(training_session, nil, locale),
      application_id: @application.id,
      support_email: ProgramContact.support_email,
      footer_text: footer_text(contact_email: ProgramContact.support_email, website_url: ProgramContact.website_url,
                               organization_name: Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program',
                               show_automated_message: true, locale: locale)
    }
    title = header_title_from_template_subject(template: text_template, subject_variables: variables,
                                               fallback: I18n.t("letters.pdf.titles.#{template_name}", locale: locale))
    variables[:header_text] = header_text(title: title, locale: locale)
    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, locale: locale, application: @application)

    send_email(recipient_email_for(constituent), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, constituent, template_name)
    raise
  end

  def training_scheduled(training_session, notification = nil)
    @application = training_session.application
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    @notification_locale = locale
    template_name = 'training_session_notifications_training_scheduled'
    begin
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.class.name}"
      raise "Email templates not found for #{template_name}"
    end

    trainer = training_session.trainer
    application = training_session.application

    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Scheduled - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = ProgramContact.website_url
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program'
    header_logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end

    variables = {
      constituent_name: constituent.full_name || 'Valued Constituent',
      constituent_full_name: constituent.full_name || 'Valued Constituent',
      trainer_name: trainer.full_name || 'Your Trainer',
      trainer_full_name: trainer.full_name || 'Your Trainer',
      trainer_email: trainer.email,
      trainer_phone_formatted: trainer.phone,
      scheduled_date: formatted_training_date(notification_scheduled_for(training_session, notification)),
      scheduled_time: formatted_training_time(notification_scheduled_for(training_session, notification)),
      scheduled_date_formatted: formatted_training_date(notification_scheduled_for(training_session, notification)),
      scheduled_time_formatted: formatted_training_time(notification_scheduled_for(training_session, notification)),
      scheduled_location: notification_location(training_session, notification, locale),
      application_id: application.id,
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, locale: locale, application: application)

    send_email(recipient_email_for(constituent), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, trainer, template_name)
    raise
  end

  def training_rescheduled(training_session, notification = nil)
    @application = training_session.application
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    @notification_locale = locale
    template_name = 'training_session_notifications_training_rescheduled'
    begin
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.class.name}"
      raise "Email templates not found for #{template_name}"
    end

    trainer = training_session.trainer
    application = training_session.application
    old_scheduled_for = notification_time(notification, 'old_scheduled_for')

    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Rescheduled - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = ProgramContact.website_url
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program'
    header_logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end

    variables = {
      constituent_name: constituent.full_name || 'Valued Constituent',
      constituent_full_name: constituent.full_name || 'Valued Constituent',
      trainer_name: trainer.full_name || 'Your Trainer',
      trainer_full_name: trainer.full_name || 'Your Trainer',
      trainer_email: trainer.email,
      trainer_phone_formatted: trainer.phone,
      old_scheduled_date: formatted_training_date(old_scheduled_for),
      old_scheduled_time: formatted_training_time(old_scheduled_for),
      old_scheduled_date_formatted: formatted_training_date(old_scheduled_for),
      old_scheduled_time_formatted: formatted_training_time(old_scheduled_for),
      scheduled_date: formatted_training_date(notification_scheduled_for(training_session, notification)),
      scheduled_time: formatted_training_time(notification_scheduled_for(training_session, notification)),
      scheduled_date_formatted: formatted_training_date(notification_scheduled_for(training_session, notification)),
      scheduled_time_formatted: formatted_training_time(notification_scheduled_for(training_session, notification)),
      scheduled_date_time_formatted: training_session_schedule_text(training_session, notification),
      scheduled_location: notification_location(training_session, notification, locale),
      # Existing stored templates use this placeholder. Supply the public scheduling fact, never the private rationale.
      reschedule_reason: I18n.t('training_session_notifications.rescheduled_at_constituent_request', locale: locale),
      application_id: application.id,
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, locale: locale, application: application)

    send_email(recipient_email_for(constituent), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, trainer, template_name)
    raise
  end

  def training_cancelled(training_session, notification = nil)
    @application = training_session.application
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    @notification_locale = locale
    template_name = 'training_session_notifications_training_cancelled'
    begin
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.class.name}"
      raise "Email templates not found for #{template_name}"
    end

    trainer = training_session.trainer
    application = training_session.application

    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Cancelled - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = ProgramContact.website_url
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program'
    header_logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end

    variables = {
      constituent_name: constituent.full_name || 'Valued Constituent',
      constituent_full_name: constituent.full_name || 'Valued Constituent',
      trainer_name: trainer.full_name || 'Your Trainer',
      scheduled_date: formatted_training_date(notification_scheduled_for(training_session, notification)),
      scheduled_time: formatted_training_time(notification_scheduled_for(training_session, notification)),
      scheduled_date_time_formatted: training_session_schedule_text(training_session, notification),
      cancellation_message: cancellation_message(training_session, locale, notification),
      scheduled_location: notification_location(training_session, notification, locale),
      application_id: application.id,
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, locale: locale, application: application)

    send_email(recipient_email_for(constituent), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, trainer, template_name)
    raise
  end

  def no_show_notification(training_session, notification = nil)
    @application = training_session.application
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    @notification_locale = locale
    template_name = 'training_session_notifications_training_no_show'
    begin
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.class.name}"
      raise "Email templates not found for #{template_name}"
    end

    trainer = training_session.trainer
    application = training_session.application

    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Session Missed - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = ProgramContact.website_url
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program'
    header_logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end

    variables = {
      constituent_name: constituent.full_name || 'Valued Constituent',
      constituent_full_name: constituent.full_name || 'Valued Constituent',
      trainer_name: trainer.full_name || 'Your Trainer',
      trainer_email: trainer.email,
      missed_date: formatted_training_date(notification_scheduled_for(training_session, notification)),
      missed_time: formatted_training_time(notification_scheduled_for(training_session, notification)),
      scheduled_date_time_formatted: training_session_schedule_text(training_session, notification),
      scheduled_location: notification_location(training_session, notification, locale),
      application_id: application.id,
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, locale: locale, application: application)

    send_email(recipient_email_for(constituent), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, trainer, template_name)
    raise
  end

  def training_completed(training_session, notification = nil)
    @application = training_session.application
    constituent = training_session.constituent
    trainer = training_session.trainer
    locale = resolve_template_locale(recipient: constituent)
    @notification_locale = locale
    template_name = 'training_session_notifications_training_completed'
    text_template = find_text_template(template_name, locale: locale)
    actual_completion = notification_time(notification, 'completed_at') || training_session.completed_at
    contact = application_contact_context_for(constituent)
    recipient = prefers_letter_delivery?(constituent) ? contact.address_owner : contact.email_owner
    report_accessible = @application.accessible_by?(recipient)
    variables = {
      recipient_full_name: recipient&.full_name,
      constituent_full_name: constituent.full_name,
      trainer_full_name: trainer.full_name,
      completed_date_formatted: formatted_training_date(actual_completion),
      completed_time_formatted: formatted_training_time(actual_completion),
      report_access_text: I18n.t("training_session_notifications.training_completed.#{report_accessible ? 'report_accessible' : 'report_managed'}", locale: locale),
      # Existing edited templates may require this scalar even when the contact owner cannot open the report.
      report_url: report_accessible ? constituent_portal_training_session_url(training_session) : '',
      footer_text: footer_text(contact_email: ProgramContact.support_email, website_url: ProgramContact.website_url,
                               organization_name: Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program',
                               show_automated_message: true, locale: locale)
    }
    title = header_title_from_template_subject(template: text_template, subject_variables: variables,
                                               fallback: I18n.t("letters.pdf.titles.#{template_name}", locale: locale))
    variables[:header_text] = header_text(title: title, locale: locale)
    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, locale: locale, application: @application)

    send_email(recipient_email_for(constituent), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, trainer, template_name)
    raise
  end

  private

  def deliver_trainer_notice(template_name, fallback_title:, message:)
    training_session = params[:assignment]
    trainer = params[:recipient]
    @application = training_session.application
    superseded = superseded_assignment_delivery(training_session, operation_id: params[:operation_id], recipient: trainer)
    return superseded if superseded

    locale = resolve_template_locale(recipient: trainer)
    @notification_locale = locale
    text_template = find_text_template(template_name, locale: locale)
    constituent = training_session.constituent
    contact = Applications::ContactContext.new(application: @application)
    title = header_title_from_template_subject(template: text_template, subject_variables: { application_id: @application.id },
                                               fallback: "#{fallback_title} - Application ##{@application.id}")
    header_logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end
    support_email = Policy.get('support_email') || 'mat.program1@maryland.gov'

    variables = {
      trainer_full_name: trainer.full_name,
      trainer_email: trainer.email,
      trainer_phone_formatted: trainer.phone,
      constituent_full_name: constituent.full_name,
      constituent_address_formatted: format_constituent_address(contact.address_owner).presence || localized_not_specified(locale),
      constituent_phone_formatted: contact.phone.presence || localized_not_specified(locale),
      constituent_email: contact.email.presence || localized_not_specified(locale),
      constituent_disabilities_text_list: format_disabilities_text(constituent, locale),
      constituent_language: format_constituent_language(contact, locale),
      constituent_contact_method: format_constituent_contact_method(contact, locale),
      constituent_communication_modality: format_constituent_communication_modality(contact, locale),
      status_box_text: status_box_text(status: :info, title: 'Training Assignment', message: message),
      application_id: @application.id,
      training_session_schedule_text: training_session_schedule_text(training_session),
      header_text: header_text(title: title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: support_email, website_url: ProgramContact.website_url,
                               organization_name: Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program',
                               show_automated_message: true, locale: locale),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: support_email
    }.compact

    send_email(recipient_email_for(trainer), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, trainer, template_name)
    raise
  end

  def training_session_schedule_text(training_session, notification = nil)
    scheduled_for = notification_scheduled_for(training_session, notification)
    return I18n.t('training_session_notifications.not_scheduled_yet', locale: @notification_locale || I18n.locale) if scheduled_for.blank?

    I18n.l(scheduled_for, format: :long, locale: @notification_locale || I18n.locale) + scheduled_for.strftime(' %Z')
  end

  def cancellation_message(training_session, locale, notification)
    I18n.with_locale(locale) do
      if notification_scheduled_for(training_session, notification).present?
        I18n.t('training_session_notifications.training_cancelled.scheduled_message',
               scheduled_for: training_session_schedule_text(training_session, notification))
      else
        I18n.t('training_session_notifications.training_cancelled.unscheduled_message')
      end
    end
  end

  def formatted_training_date(value)
    value ? I18n.l(value.to_date, format: :long, locale: @notification_locale || I18n.locale) : localized_not_specified(@notification_locale || I18n.locale)
  end

  def formatted_training_time(value)
    value ? I18n.l(value, format: '%H:%M %Z', locale: @notification_locale || I18n.locale) : localized_not_specified(@notification_locale || I18n.locale)
  end

  def notification_scheduled_for(training_session, notification)
    return notification_time(notification, 'scheduled_for') if notification&.metadata&.key?('scheduled_for')

    training_session.scheduled_for
  end

  def notification_location(training_session, notification, locale)
    location = notification ? notification.metadata['location'] : training_session.location
    location.presence || localized_not_specified(locale)
  end

  def notification_time(notification, metadata_key)
    raw_value = notification&.metadata&.dig(metadata_key)
    return if raw_value.blank?

    Time.zone.parse(raw_value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def format_constituent_address(constituent)
    [
      constituent.physical_address_1,
      constituent.physical_address_2,
      [constituent.city, constituent.state, constituent.zip_code].compact_blank.join(' ')
    ].compact_blank.join("\n")
  end

  def format_disabilities_text(constituent, locale)
    disabilities = %i[hearing vision speech mobility cognition].filter_map do |disability|
      I18n.t("application_contact.disability_types.#{disability}", locale: locale) if constituent.public_send("#{disability}_disability")
    end

    return I18n.t('application_contact.no_disabilities_recorded', locale: locale) if disabilities.blank?

    disabilities.map { |disability| "- #{disability}" }.join("\n")
  end

  def format_constituent_language(contact, template_locale)
    language = contact.locale.to_s == 'es' ? :spanish : :english
    localized_label(language, locale: template_locale)
  end

  def format_constituent_contact_method(contact, locale)
    localized_label(contact.phone_type.to_s, locale: locale)
  end

  def format_constituent_communication_modality(contact, locale)
    localized_label(contact.communication_modality.to_s, locale: locale)
  end

  def localized_label(value, locale:)
    I18n.t("training_session_notifications.trainer_assigned.labels.#{value}",
           default: localized_not_specified(locale),
           locale: locale)
  end

  def localized_not_specified(locale)
    I18n.t('training_session_notifications.trainer_assigned.labels.not_specified',
           default: 'Not specified',
           locale: locale)
  end
end
