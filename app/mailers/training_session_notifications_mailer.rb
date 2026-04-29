# frozen_string_literal: true

class TrainingSessionNotificationsMailer < ApplicationMailer
  include Rails.application.routes.url_helpers
  # Include helpers for rendering shared partials
  include Mailers::SharedPartialHelpers # Use the extracted shared helper module

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  # Notify a trainer that a new training session has been assigned
  # Expects training_session passed via .with(training_session: ...)
  def trainer_assigned(training_session)
    training_session = training_session
    trainer = training_session.trainer
    locale = resolve_template_locale(recipient: trainer)
    template_name = 'training_session_notifications_trainer_assigned'
    begin
      # Only find the text template as per project strategy
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    constituent = training_session.constituent
    application = training_session.application

    # Common elements for shared partials
    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "New Training Assignment - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'MAT-Vulcan'
    header_logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end

    variables = {
        trainer_full_name: trainer.full_name,
        trainer_email: trainer.email,
        trainer_phone_formatted: trainer.phone,
        constituent_full_name: constituent.full_name,
        constituent_address_formatted: format_constituent_address(constituent),
        constituent_phone_formatted: constituent.phone,
        constituent_email: recipient_email_for(constituent),
        constituent_disabilities_text_list: format_disabilities_text(constituent),
        status_box_text: status_box_text(status: :info, title: 'Training Assignment', message: 'Please contact the constituent to schedule this training session.'),
        application_id: application.id,
        training_session_schedule_text: training_session_schedule_text(training_session),
      # Shared partial variables (rendered content - text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url, # Optional, passed for potential use in template body
      header_subtitle: nil, # Optional
      support_email: footer_contact_email
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send trainer_assigned email with content: #{text_body.inspect}" }

    mail(
      to: trainer.email,
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Update error logging to include template name and variables
    AuditEventService.log(
      actor: trainer, # Use local variable
      action: 'email_delivery_error',
      auditable: trainer,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: e.message,
        error_class: e.class.name,
        template_name: template_name, # Use local variable
        variables: variables, # Use local variable
        backtrace: e.backtrace&.first(5)
      }
    )
    raise
  end

  # Notify constituent that training is scheduled
  # Expects training_session passed via .with(training_session: ...)
  def training_scheduled(training_session)
    training_session = training_session
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    template_name = 'training_session_notifications_training_scheduled'
    begin
      # Only find the text template as per project strategy
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Scheduled - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'MAT-Vulcan'
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
        scheduled_date: formatted_training_date(training_session.scheduled_for),
        scheduled_time: formatted_training_time(training_session.scheduled_for),
        scheduled_date_formatted: formatted_training_date(training_session.scheduled_for),
        scheduled_time_formatted: formatted_training_time(training_session.scheduled_for),
        application_id: application.id,
      # Shared partial variables (text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url, # Optional
      header_subtitle: nil, # Optional
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, application: application)

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send training_scheduled email with content: #{text_body.inspect}" }

    mail(
      to: recipient_email_for(constituent),
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Log error with more details
    AuditEventService.log(
      actor: trainer, # Use local variable if available, otherwise nil
      action: 'email_delivery_error',
      auditable: trainer,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: e.message,
        error_class: e.class.name,
        template_name: template_name, # Use local variable
        variables: variables, # Use local variable
        backtrace: e.backtrace&.first(5)
      }
    )
    raise
  end

  # Notify constituent that training is rescheduled
  def training_rescheduled(training_session, notification = nil)
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    template_name = 'training_session_notifications_training_rescheduled'
    begin
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    trainer = training_session.trainer
    application = training_session.application
    old_scheduled_for = notification_time(notification, 'old_scheduled_for') ||
                        training_session.saved_change_to_scheduled_for&.first
    reschedule_reason = notification&.metadata&.dig('reschedule_reason').presence ||
                        training_session.reschedule_reason

    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Rescheduled - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'MAT-Vulcan'
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
      scheduled_date: formatted_training_date(training_session.scheduled_for),
      scheduled_time: formatted_training_time(training_session.scheduled_for),
      scheduled_date_formatted: formatted_training_date(training_session.scheduled_for),
      scheduled_time_formatted: formatted_training_time(training_session.scheduled_for),
      scheduled_date_time_formatted: training_session_schedule_text(training_session),
      reschedule_reason: reschedule_reason,
      application_id: application.id,
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, application: application)

    rendered_subject, rendered_text_body = text_template.render(**variables)

    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send training_rescheduled email with content: #{text_body.inspect}" }

    mail(
      to: recipient_email_for(constituent),
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    AuditEventService.log(
      actor: trainer,
      action: 'email_delivery_error',
      auditable: trainer,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: e.message,
        error_class: e.class.name,
        template_name: template_name,
        variables: variables,
        backtrace: e.backtrace&.first(5)
      }
    )
    raise
  end

  # Notify constituent that training is completed
  # Expects training_session passed via .with(training_session: ...)
  def training_completed(training_session)
    training_session = training_session
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    template_name = 'training_session_notifications_training_completed'
    begin
      # Only find the text template as per project strategy
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Completed - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'MAT-Vulcan'
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
        completion_date: training_session.completed_at.strftime('%B %d, %Y'),
        completed_date_formatted: formatted_training_date(training_session.completed_at),
        application_id: application.id,
      # Shared partial variables (text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url, # Optional
      header_subtitle: nil, # Optional
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, application: application)

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send training_completed email with content: #{text_body.inspect}" }

    mail(
      to: recipient_email_for(constituent),
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Log error with more details
    AuditEventService.log(
      actor: trainer, # Use local variable if available, otherwise nil
      action: 'email_delivery_error',
      auditable: trainer,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: e.message,
        error_class: e.class.name,
        template_name: template_name, # Use local variable
        variables: variables, # Use local variable
        backtrace: e.backtrace&.first(5)
      }
    )
    raise
  end

  # Notify constituent that training is cancelled
  def training_cancelled(training_session)
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    template_name = 'training_session_notifications_training_cancelled'
    begin
      # Only find the text template as per project strategy
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Cancelled - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'MAT-Vulcan'
    header_logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end

    variables = {
      constituent_name: constituent.full_name || 'Valued Constituent',
      constituent_full_name: constituent.full_name || 'Valued Constituent',
      trainer_name: trainer.full_name || 'Your Trainer',
      scheduled_date: formatted_training_date(training_session.scheduled_for),
      scheduled_time: formatted_training_time(training_session.scheduled_for),
      scheduled_date_time_formatted: training_session_schedule_text(training_session),
      cancellation_message: cancellation_message(training_session, locale),
      application_id: application.id,
      # Shared partial variables (text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url, # Optional
      header_subtitle: nil, # Optional
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, application: application)

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send training_cancelled email with content: #{text_body.inspect}" }

    mail(
      to: recipient_email_for(constituent),
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Log error with more details
    AuditEventService.log(
      actor: trainer, # Use local variable if available, otherwise nil
      action: 'email_delivery_error',
      auditable: trainer,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: e.message,
        error_class: e.class.name,
        template_name: template_name, # Use local variable
        variables: variables, # Use local variable
        backtrace: e.backtrace&.first(5)
      }
    )
    raise
  end

  # Notify constituent about a no-show for training
  def no_show_notification(training_session)
    # Use full template name as defined in the constant
    constituent = training_session.constituent
    locale = resolve_template_locale(recipient: constituent)
    template_name = 'training_session_notifications_training_no_show'
    begin
      # Only find the text template as per project strategy
      text_template = find_text_template(template_name, locale: locale)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = header_title_from_template_subject(
      template: text_template,
      subject_variables: { application_id: application.id },
      fallback: "Training Session Missed - Application ##{application.id}"
    )
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'MAT-Vulcan'
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
        missed_date: formatted_training_date(training_session.scheduled_for),
        missed_time: formatted_training_time(training_session.scheduled_for),
        scheduled_date_time_formatted: training_session_schedule_text(training_session),
        application_id: application.id,
      # Shared partial variables (text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message,
                               locale: locale),
      header_logo_url: header_logo_url, # Optional
      header_subtitle: nil, # Optional
      support_email: footer_contact_email
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(constituent, template_name, variables, application: application)

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send no_show_notification email with content: #{text_body.inspect}" }

    mail(
      to: recipient_email_for(constituent),
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Log error with more details
    AuditEventService.log(
      actor: trainer, # Use local variable if available, otherwise nil
      action: 'email_delivery_error',
      auditable: trainer,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: e.message,
        error_class: e.class.name,
        template_name: template_name, # Use local variable
        variables: variables, # Use local variable
        backtrace: e.backtrace&.first(5)
      }
    )
    raise
  end

  private

  def training_session_schedule_text(training_session)
    return 'Not scheduled yet' if training_session.scheduled_for.blank?

    training_session.scheduled_for.strftime('%B %d, %Y at %I:%M %p')
  end

  def cancellation_message(training_session, locale)
    I18n.with_locale(locale) do
      if training_session.scheduled_for.present?
        I18n.t('training_session_notifications.training_cancelled.scheduled_message',
               scheduled_for: training_session_schedule_text(training_session))
      else
        I18n.t('training_session_notifications.training_cancelled.assignment_removed_message')
      end
    end
  end

  def formatted_training_date(value)
    value&.strftime('%B %d, %Y') || 'not scheduled'
  end

  def formatted_training_time(value)
    value&.strftime('%I:%M %p') || 'not scheduled'
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

  def format_disabilities_text(constituent)
    disabilities = %i[hearing vision speech mobility cognition].filter_map do |disability|
      disability.to_s.titleize if constituent.public_send("#{disability}_disability")
    end

    return 'No disabilities recorded' if disabilities.blank?

    disabilities.map { |disability| "- #{disability}" }.join("\n")
  end

  def queue_letter_if_preferred(constituent, template_name, variables, application: nil)
    return false unless prefers_letter_delivery?(constituent)

    queue_letter_delivery(
      recipient: constituent,
      template_name: template_name,
      variables: variables,
      application: application
    )
    true
  end
end
