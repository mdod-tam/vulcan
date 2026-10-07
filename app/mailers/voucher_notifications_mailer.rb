# frozen_string_literal: true

class VoucherNotificationsMailer < ApplicationMailer
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::NumberHelper
  include Mailers::SharedPartialHelpers

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  def voucher_assigned
    voucher = params[:voucher]
    user = voucher.application.user
    locale = resolve_template_locale(recipient: user)
    template_name = 'voucher_notifications_voucher_assigned'

    text_template = voucher_text_template(template_name, locale)

    layout = layout_variables(text_template, locale: locale, fallback_title: I18n.t('mailers.voucher_notifications.assigned_header', locale: locale),
                                             voucher_code: voucher.code, user_first_name: user.first_name)

    variables = {
      user_first_name: user.first_name,
      voucher_code: voucher.code,
      initial_value_formatted: number_to_currency(voucher.initial_value, locale: locale),
      expiration_date_formatted: I18n.l(voucher.expiration_date.to_date, format: :long, locale: locale),
      validity_period_months: Policy.get('voucher_validity_period_months') || 6,
      minimum_redemption_amount_formatted: number_to_currency(Policy.get('minimum_voucher_redemption_amount') || 0, locale: locale),
      **layout
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(user, template_name, variables, locale: locale, application: voucher.application)

    send_email(recipient_email_for(user), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, user, template_name)
    raise e
  end

  def voucher_expiring_soon
    voucher = params[:voucher]
    user = voucher.application.user
    locale = resolve_template_locale(recipient: user)
    template_name = 'voucher_notifications_voucher_expiring_soon'

    text_template = voucher_text_template(template_name, locale)

    layout = layout_variables(text_template, locale: locale, fallback_title: I18n.t('mailers.voucher_notifications.expiring_soon.header_fallback', locale: locale),
                                             voucher_code: voucher.code, user_first_name: user.first_name)
    expiration_date = voucher.issued_at + (Policy.get('voucher_validity_period_months') || 6).months
    days_remaining = (expiration_date - Time.current).to_i / 1.day
    expiration_date_formatted = I18n.l(expiration_date.to_date, format: :long, locale: locale)
    minimum_redemption_amount_formatted = number_to_currency(Policy.get('minimum_voucher_redemption_amount') || 0,
                                                             locale: locale)
    expiration_message = I18n.t(
      'mailers.voucher_notifications.expiring_soon.expiration_message',
      locale: locale,
      days_remaining: days_remaining,
      expiration_date: expiration_date_formatted
    )

    variables = {
      user_first_name: user.first_name,
      vendor_business_name: user.full_name.presence || user.first_name,
      voucher_code: voucher.code,
      days_remaining: days_remaining,
      days_until_expiry: days_remaining,
      expiration_date_formatted: expiration_date_formatted,
      remaining_value_formatted: number_to_currency(voucher.remaining_value, locale: locale),
      minimum_redemption_amount_formatted: minimum_redemption_amount_formatted,
      status_box_warning_text: status_box_text(
        status: :warning,
        title: I18n.t('mailers.voucher_notifications.expiring_soon.warning_title', locale: locale),
        message: expiration_message
      ),
      status_box_info_text: status_box_text(
        status: :info,
        title: I18n.t('mailers.voucher_notifications.expiring_soon.next_step_title', locale: locale),
        message: I18n.t(
          'mailers.voucher_notifications.expiring_soon.next_step_message',
          locale: locale,
          minimum_redemption_amount: minimum_redemption_amount_formatted
        )
      ),
      **layout
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(user, template_name, variables, locale: locale, application: voucher.application)

    send_email(recipient_email_for(user), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, user, template_name)
    raise e
  end

  def voucher_expired
    voucher = params[:voucher]
    user = voucher.application.user
    locale = resolve_template_locale(recipient: user)
    template_name = 'voucher_notifications_voucher_expired'

    text_template = voucher_text_template(template_name, locale)

    layout = layout_variables(text_template, locale: locale, fallback_title: I18n.t('mailers.voucher_notifications.expired_header', locale: locale),
                                             voucher_code: voucher.code, user_first_name: user.first_name)

    transaction_history_text = ''
    if voucher.transactions.any?
      transaction_history_text = voucher.transactions.order(created_at: :desc).map do |t|
        I18n.t('mailers.voucher_notifications.transaction_history_entry', locale: locale,
                                                                          date: I18n.l(t.created_at.to_date, format: :long, locale: locale),
                                                                          amount: number_to_currency(t.amount, locale: locale), vendor: t.vendor.business_name)
      end.join("\n")
    end

    variables = {
      user_first_name: user.first_name,
      voucher_code: voucher.code,
      initial_value_formatted: number_to_currency(voucher.initial_value, locale: locale),
      unused_value_formatted: number_to_currency(voucher.remaining_value, locale: locale),
      expiration_date_formatted: I18n.l(voucher.expiration_date.to_date, format: :long, locale: locale),
      **layout,
      transaction_history_text: transaction_history_text,
      show_automated_message: true
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(user, template_name, variables, locale: locale, application: voucher.application)

    send_email(recipient_email_for(user), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, user, template_name)
    raise e
  end

  def voucher_redeemed
    transaction = params[:transaction]
    voucher = transaction.voucher
    user = voucher.application.user
    vendor = transaction.vendor
    locale = resolve_template_locale(recipient: user)
    template_name = 'voucher_notifications_voucher_redeemed'

    text_template = voucher_text_template(template_name, locale)

    layout = layout_variables(text_template, locale: locale, fallback_title: I18n.t('mailers.voucher_notifications.redeemed_header', locale: locale),
                                             voucher_code: voucher.code, user_first_name: user.first_name)
    remaining_balance_formatted = number_to_currency(voucher.remaining_value, locale: locale)
    expiration_date_formatted = I18n.l(voucher.expiration_date.to_date, format: :long, locale: locale)
    minimum_redemption_amount_formatted = number_to_currency(Policy.get('minimum_voucher_redemption_amount') || 0, locale: locale)
    redeemed_value_formatted = number_to_currency(transaction.amount, locale: locale)

    remaining_value_message_text = ''
    fully_redeemed_message_text = ''

    if voucher.remaining_value.positive?
      remaining_value_message_text = I18n.t(
        'mailers.voucher_notifications.remaining_balance',
        locale: locale, balance: remaining_balance_formatted, minimum: minimum_redemption_amount_formatted
      )
    else
      fully_redeemed_message_text = I18n.t('mailers.voucher_notifications.fully_redeemed', locale: locale)
    end

    variables = {
      user_first_name: user.first_name,
      transaction_date_formatted: I18n.l(transaction.created_at.to_date, format: :long, locale: locale),
      transaction_amount_formatted: number_to_currency(transaction.amount, locale: locale),
      vendor_business_name: vendor.business_name,
      transaction_reference_number: transaction.reference_number || 'N/A',
      voucher_code: voucher.code,
      remaining_balance_formatted: remaining_balance_formatted,
      expiration_date_formatted: expiration_date_formatted,
      remaining_value_message_text: remaining_value_message_text,
      redeemed_value_formatted: redeemed_value_formatted,
      fully_redeemed_message_text: fully_redeemed_message_text,
      minimum_redemption_amount_formatted: minimum_redemption_amount_formatted,
      **layout
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(user, template_name, variables, locale: locale, application: voucher.application)

    send_email(recipient_email_for(user), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, user, template_name)
    raise e
  end

  # A package's first-tracking notice. The recipient is the one TrackingNotice chose and stored on
  # the notification: the application's managing guardian, or the applicant when no one manages it.
  def shipment_tracking_added(shipment, notification)
    user = notification.recipient
    purchase = shipment.voucher_transaction
    application = purchase.voucher.application
    locale = resolve_template_locale(recipient: user)
    template_name = 'voucher_notifications_shipment_tracking_added'
    text_template = voucher_text_template(template_name, locale)
    layout = layout_variables(text_template, locale: locale, fallback_title: I18n.t('mailers.voucher_notifications.shipment_header', locale: locale),
                                             vendor_business_name: purchase.vendor.business_name)

    variables = {
      user_first_name: user.first_name,
      vendor_business_name: purchase.vendor.business_name,
      transaction_date_formatted: I18n.l(purchase.processed_at.to_date, format: :long, locale: locale),
      tracking_number: shipment.tracking_number,
      orders_url: constituent_portal_application_url(application, anchor: 'orders-and-shipping', host: default_url_options[:host]),
      **layout
    }.compact

    return noop_letter_delivery if queue_letter_if_preferred(user, template_name, variables, locale: locale, application: application)

    send_email(recipient_email_for(user), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, user, template_name)
    raise e
  end

  private

  def voucher_text_template(template_name, locale)
    find_text_template(template_name, locale: locale)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
    raise "Email template (text format) not found for #{template_name}"
  end

  # The header, footer, and support address every voucher message shares.
  def layout_variables(text_template, locale:, fallback_title:, **subject_variables)
    support_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    logo_url = begin
      ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
    rescue StandardError
      nil
    end
    title = header_title_from_template_subject(template: text_template, subject_variables: subject_variables, fallback: fallback_title)

    {
      header_text: header_text(title: title, logo_url: logo_url, locale: locale),
      footer_text: footer_text(contact_email: support_email, website_url: ProgramContact.website_url,
                               organization_name: Policy.get('organization_name') || 'Maryland Accessible Telecommunications Program',
                               show_automated_message: true, locale: locale),
      support_email: support_email
    }
  end
end
