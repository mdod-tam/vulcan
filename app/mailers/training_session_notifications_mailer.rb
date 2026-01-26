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
  def trainer_assigned
    training_session = params[:training_session] # Use params
    template_name = 'training_session_notifications_trainer_assigned'
    begin
      # Only find the text template as per project strategy
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    constituent = training_session.constituent
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = "New Training Assignment - Application ##{application.id}"
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
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
      constituent_full_name: constituent.full_name,
      application_id: application.id,
      # Shared partial variables (rendered content - text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message),
      header_logo_url: header_logo_url, # Optional, passed for potential use in template body
      header_subtitle: nil # Optional
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
  def training_scheduled
    training_session = params[:training_session] # Use params
    template_name = 'training_session_notifications_training_scheduled'
    begin
      # Only find the text template as per project strategy
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    constituent = training_session.constituent
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = "Training Scheduled - Application ##{application.id}"
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
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
      trainer_name: trainer.full_name || 'Your Trainer',
      scheduled_date: training_session.scheduled_for.strftime('%B %d, %Y'),
      scheduled_time: training_session.scheduled_for.strftime('%I:%M %p'),
      application_id: application.id,
      # Shared partial variables (text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message),
      header_logo_url: header_logo_url, # Optional
      header_subtitle: nil # Optional
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send training_scheduled email with content: #{text_body.inspect}" }

    mail(
      to: constituent.email, # Fixed: should send to constituent, not trainer
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

  # Notify constituent that training is completed
  # Expects training_session passed via .with(training_session: ...)
  def training_completed
    training_session = params[:training_session] # Use params
    template_name = 'training_session_notifications_training_completed'
    begin
      # Only find the text template as per project strategy
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    constituent = training_session.constituent
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = "Training Completed - Application ##{application.id}"
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
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
      trainer_name: trainer.full_name || 'Your Trainer',
      completion_date: training_session.completed_at.strftime('%B %d, %Y'),
      application_id: application.id,
      # Shared partial variables (text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message),
      header_logo_url: header_logo_url, # Optional
      header_subtitle: nil # Optional
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send training_completed email with content: #{text_body.inspect}" }

    mail(
      to: constituent.email,
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
    template_name = 'training_session_notifications_training_cancelled'
    begin
      # Only find the text template as per project strategy
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    constituent = training_session.constituent
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = "Training Cancelled - Application ##{application.id}"
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
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
      trainer_name: trainer.full_name || 'Your Trainer',
      scheduled_date: training_session.scheduled_for.strftime('%B %d, %Y'),
      scheduled_time: training_session.scheduled_for.strftime('%I:%M %p'),
      application_id: application.id,
      # Shared partial variables (text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message),
      header_logo_url: header_logo_url, # Optional
      header_subtitle: nil # Optional
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send training_cancelled email with content: #{text_body.inspect}" }

    mail(
      to: constituent.email,
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
    template_name = 'training_session_notifications_training_no_show'
    begin
      # Only find the text template as per project strategy
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email templates not found for #{template_name}"
    end

    # Prepare variables
    constituent = training_session.constituent
    trainer = training_session.trainer
    application = training_session.application

    # Common elements for shared partials
    header_title = "Training Session Missed - Application ##{application.id}"
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
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
      trainer_name: trainer.full_name || 'Your Trainer',
      missed_date: training_session.scheduled_for.strftime('%B %d, %Y'),
      missed_time: training_session.scheduled_for.strftime('%I:%M %p'),
      application_id: application.id,
      # Shared partial variables (text only for non-multipart emails)
      header_text: header_text(title: header_title, logo_url: header_logo_url),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message),
      header_logo_url: header_logo_url, # Optional
      header_subtitle: nil # Optional
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send no_show_notification email with content: #{text_body.inspect}" }

    mail(
      to: constituent.email,
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
end
