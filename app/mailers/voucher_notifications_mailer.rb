# frozen_string_literal: true

class VoucherNotificationsMailer < ApplicationMailer
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::NumberHelper # For number_to_currency
  include Mailers::SharedPartialHelpers # Include the shared helpers for header_text and footer_text

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  # Removed prepare_email helper

  def voucher_assigned
    voucher = params[:voucher]
    user = voucher.application.user
    template_name = 'voucher_notifications_voucher_assigned'

    begin
      # Only find the text template as per project strategy
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email template (text format) not found for #{template_name}"
    end

    # Prepare variables
    variables = {
      user_first_name: user.first_name,
      voucher_code: voucher.code,
      initial_value_formatted: number_to_currency(voucher.initial_value),
      # Use Policy.get for configuration values
      expiration_date_formatted: (voucher.issued_at + (Policy.get('voucher_validity_period_months') || 6).months).strftime('%B %d, %Y'),
      validity_period_months: Policy.get('voucher_validity_period_months') || 6,
      minimum_redemption_amount_formatted: number_to_currency(Policy.get('minimum_voucher_redemption_amount') || 0)
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send voucher_assigned email with content: #{text_body.inspect}" }

    mail(
      to: user.email,
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Log error with more details
    AuditEventService.log(
      actor: user,
      action: 'email_delivery_error',
      auditable: user,
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
    raise e
  end

  def voucher_expiring_soon
    voucher = params[:voucher]
    user = voucher.application.user
    template_name = 'voucher_notifications_voucher_expiring_soon'

    begin
      # Find the text template
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email template (text format) not found for #{template_name}"
    end

    # Prepare variables
    # Use Policy.get for configuration values
    expiration_date = voucher.issued_at + (Policy.get('voucher_validity_period_months') || 6).months
    days_remaining = (expiration_date - Time.current).to_i / 1.day

    variables = {
      user_first_name: user.first_name,
      voucher_code: voucher.code,
      days_remaining: days_remaining,
      expiration_date_formatted: expiration_date.strftime('%B %d, %Y')
      # Add other required variables from AVAILABLE_TEMPLATES if needed
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send voucher_expiring_soon email with content: #{text_body.inspect}" }

    mail(
      to: user.email,
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Log error with more details
    AuditEventService.log(
      actor: user,
      action: 'email_delivery_error',
      auditable: user,
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
    raise e
  end

  def voucher_expired
    voucher = params[:voucher]
    user = voucher.application.user
    template_name = 'voucher_notifications_voucher_expired'

    begin
      # Find the text template
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email template (text format) not found for #{template_name}"
    end

    # Common elements for shared partials
    header_title = 'Important: Your Voucher Has Expired'
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    organization_name = Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program'
    header_logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end

    # Optional: Render transaction history if needed for the template (text only)
    transaction_history_text = ''
    if voucher.transactions.any?
      transaction_history_text = voucher.transactions.order(created_at: :desc).map do |t|
        "- #{t.created_at.strftime('%m/%d/%Y')}: #{number_to_currency(t.amount)} at #{t.vendor.business_name}"
      end.join("\n")
    end

    variables = {
      user_first_name: user.first_name,
      voucher_code: voucher.code,
      initial_value_formatted: number_to_currency(voucher.initial_value),
      unused_value_formatted: number_to_currency(voucher.remaining_value),
      # Use Policy.get for configuration values
      expiration_date_formatted: (voucher.issued_at + (Policy.get('voucher_validity_period_months') || 6).months).strftime('%B %d, %Y'),
      # Required header and footer text
      header_text: header_text(title: header_title, logo_url: header_logo_url),
      footer_text: footer_text(contact_email: footer_contact_email, website_url: footer_website_url,
                               organization_name: organization_name, show_automated_message: footer_show_automated_message),
      # Optional variables
      transaction_history_text: transaction_history_text,
      title: header_title, # Optional
      logo: header_logo_url, # Optional
      subtitle: nil, # Optional
      show_automated_message: footer_show_automated_message # Optional
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send voucher_expired email with content: #{text_body.inspect}" }

    mail(
      to: user.email,
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Log error with more details
    AuditEventService.log(
      actor: user,
      action: 'email_delivery_error',
      auditable: user,
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
    raise e
  end

  def voucher_redeemed
    transaction = params[:transaction]
    voucher = transaction.voucher
    user = voucher.application.user
    vendor = transaction.vendor
    template_name = 'voucher_notifications_voucher_redeemed'

    begin
      # Find the text template
      text_template = EmailTemplate.find_by!(name: template_name, format: :text)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
      raise "Email template (text format) not found for #{template_name}"
    end

    header_content, _ = EmailTemplate.render('email_header_text',
      title: 'Voucher Redeemed',
      subtitle: ''
    )
    footer_content, _ = EmailTemplate.render('email_footer_text', 
      organization_name: Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program',
      contact_email: Policy.get('support_email') || 'support@example.com',
      website_url: root_url(host: default_url_options[:host]),
      automated_message_text: 'This is an automated message. Please do not reply directly to this email.'
    )
    # Prepare variables
    remaining_balance_formatted = number_to_currency(voucher.remaining_value) # After transaction
    # Use Policy.get for configuration values
    expiration_date_formatted = (voucher.issued_at + (Policy.get('voucher_validity_period_months') || 6).months).strftime('%B %d, %Y')
    minimum_redemption_amount_formatted = number_to_currency(Policy.get('minimum_voucher_redemption_amount') || 0)
    redeemed_value_formatted = number_to_currency(transaction.amount)

    # Optional message blocks (text only)
    remaining_value_message_text = ''
    fully_redeemed_message_text = ''

    if voucher.remaining_value.positive?
      # Simplified example - actual content depends on template placeholders
      remaining_value_message_text = "Your remaining balance is #{remaining_balance_formatted}. Minimum redemption amount is #{minimum_redemption_amount_formatted}."
    else
      fully_redeemed_message_text = 'This voucher has been fully redeemed.'
    end

    variables = {
      user_first_name: user.first_name,
      transaction_date_formatted: transaction.created_at.strftime('%B %d, %Y'),
      transaction_amount_formatted: number_to_currency(transaction.amount),
      vendor_business_name: vendor.business_name,
      transaction_reference_number: transaction.reference_number || 'N/A',
      voucher_code: voucher.code,
      remaining_balance_formatted: remaining_balance_formatted,
      expiration_date_formatted: expiration_date_formatted,
      # Optional variables
      remaining_value_message_text: remaining_value_message_text,
      redeemed_value_formatted: redeemed_value_formatted,
      fully_redeemed_message_text: fully_redeemed_message_text,
      minimum_redemption_amount_formatted: minimum_redemption_amount_formatted,# Often used within optional blocks
      header_text: header_content,
      footer_text: footer_content 
    }.compact

    # Render subject and body from the text template
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Send email as non-multipart text-only
    text_body = rendered_text_body.to_s
    Rails.logger.debug { "DEBUG: Preparing to send voucher_redeemed email with content: #{text_body.inspect}" }

    mail(
      to: user.email,
      subject: rendered_subject,
      message_stream: 'notifications',
      body: text_body,
      content_type: 'text/plain'
    )
  rescue StandardError => e
    # Log error with more details
    AuditEventService.log(
      actor: user,
      action: 'email_delivery_error',
      auditable: user,
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
    raise e
  end
end
