# frozen_string_literal: true

class VoucherNotificationsMailer < ApplicationMailer
  include ActionView::Helpers::NumberHelper

  def voucher_assigned
    voucher = params[:voucher]
    user = voucher.application.user
    locale = resolve_template_locale(recipient: user)

    deliver_voucher_notification('voucher_notifications_voucher_assigned', voucher, user, locale) do |template|
      {
        user_first_name: user.first_name,
        voucher_code: voucher.code,
        initial_value_formatted: number_to_currency(voucher.initial_value, locale: locale),
        expiration_date_formatted: I18n.l(voucher.expiration_date.to_date, format: :long, locale: locale),
        validity_period_months: Policy.get('voucher_validity_period_months') || 6,
        minimum_redemption_amount_formatted: number_to_currency(minimum_redemption_amount, locale: locale),
        **voucher_envelope(template, voucher, user, locale, I18n.t('mailers.voucher_notifications.assigned_header', locale: locale))
      }
    end
  end

  def voucher_expiring_soon
    voucher = params[:voucher]
    user = voucher.application.user
    locale = resolve_template_locale(recipient: user)

    deliver_voucher_notification('voucher_notifications_voucher_expiring_soon', voucher, user, locale) do |template|
      expiration_date = voucher.issued_at + (Policy.get('voucher_validity_period_months') || 6).months
      days_remaining = (expiration_date - Time.current).to_i / 1.day
      expiration_date_formatted = I18n.l(expiration_date.to_date, format: :long, locale: locale)
      minimum_formatted = number_to_currency(minimum_redemption_amount, locale: locale)
      expiration_message = I18n.t('mailers.voucher_notifications.expiring_soon.expiration_message',
                                  locale: locale, days_remaining: days_remaining, expiration_date: expiration_date_formatted)

      {
        user_first_name: user.first_name,
        vendor_business_name: user.full_name.presence || user.first_name,
        voucher_code: voucher.code,
        days_remaining: days_remaining,
        days_until_expiry: days_remaining,
        expiration_date_formatted: expiration_date_formatted,
        remaining_value_formatted: number_to_currency(voucher.remaining_value, locale: locale),
        minimum_redemption_amount_formatted: minimum_formatted,
        status_box_warning_text: status_box_text(
          status: :warning,
          title: I18n.t('mailers.voucher_notifications.expiring_soon.warning_title', locale: locale),
          message: expiration_message
        ),
        status_box_info_text: status_box_text(
          status: :info,
          title: I18n.t('mailers.voucher_notifications.expiring_soon.next_step_title', locale: locale),
          message: I18n.t('mailers.voucher_notifications.expiring_soon.next_step_message',
                          locale: locale, minimum_redemption_amount: minimum_formatted)
        ),
        **voucher_envelope(template, voucher, user, locale,
                           I18n.t('mailers.voucher_notifications.expiring_soon.header_fallback', locale: locale))
      }
    end
  end

  def voucher_expired
    voucher = params[:voucher]
    user = voucher.application.user
    locale = resolve_template_locale(recipient: user)

    deliver_voucher_notification('voucher_notifications_voucher_expired', voucher, user, locale) do |template|
      {
        user_first_name: user.first_name,
        voucher_code: voucher.code,
        initial_value_formatted: number_to_currency(voucher.initial_value, locale: locale),
        unused_value_formatted: number_to_currency(voucher.remaining_value, locale: locale),
        expiration_date_formatted: I18n.l(voucher.expiration_date.to_date, format: :long, locale: locale),
        transaction_history_text: transaction_history_text(voucher, locale),
        show_automated_message: true,
        **voucher_envelope(template, voucher, user, locale, I18n.t('mailers.voucher_notifications.expired_header', locale: locale))
      }
    end
  end

  def voucher_redeemed
    transaction = params[:transaction]
    voucher = transaction.voucher
    @application = voucher.application
    user = @application.user
    locale = resolve_template_locale(recipient: user)

    deliver_voucher_notification('voucher_notifications_voucher_redeemed', voucher, user, locale) do |template|
      remaining_balance_formatted = number_to_currency(voucher.remaining_value, locale: locale)
      minimum_formatted = number_to_currency(minimum_redemption_amount, locale: locale)

      {
        user_first_name: user.first_name,
        transaction_date_formatted: I18n.l(transaction.created_at.to_date, format: :long, locale: locale),
        transaction_amount_formatted: number_to_currency(transaction.amount, locale: locale),
        vendor_business_name: transaction.vendor.business_name,
        transaction_reference_number: transaction.reference_number || 'N/A',
        voucher_code: voucher.code,
        remaining_balance_formatted: remaining_balance_formatted,
        expiration_date_formatted: I18n.l(voucher.expiration_date.to_date, format: :long, locale: locale),
        remaining_value_message_text: remaining_value_message(voucher, remaining_balance_formatted, minimum_formatted, locale),
        redeemed_value_formatted: number_to_currency(transaction.amount, locale: locale),
        fully_redeemed_message_text: voucher.remaining_value.positive? ? '' : I18n.t('mailers.voucher_notifications.fully_redeemed', locale: locale),
        minimum_redemption_amount_formatted: minimum_formatted,
        **voucher_envelope(template, voucher, user, locale, I18n.t('mailers.voucher_notifications.redeemed_header', locale: locale))
      }
    end
  end

  private

  def deliver_voucher_notification(template_name, voucher, user, locale, &)
    deliver_notification(template_name, recipient: user, locale: locale, letters: true, application: voucher.application, &)
  end

  def voucher_envelope(template, voucher, user, locale, fallback_title)
    envelope_variables(template: template, locale: locale, fallback_title: fallback_title,
                       subject_variables: { voucher_code: voucher.code, user_first_name: user.first_name })
  end

  def minimum_redemption_amount
    Policy.get('minimum_voucher_redemption_amount') || 0
  end

  def transaction_history_text(voucher, locale)
    voucher.transactions.order(created_at: :desc).map do |transaction|
      I18n.t('mailers.voucher_notifications.transaction_history_entry', locale: locale,
                                                                        date: I18n.l(transaction.created_at.to_date, format: :long, locale: locale),
                                                                        amount: number_to_currency(transaction.amount, locale: locale),
                                                                        vendor: transaction.vendor.business_name)
    end.join("\n")
  end

  def remaining_value_message(voucher, remaining_balance_formatted, minimum_formatted, locale)
    return '' unless voucher.remaining_value.positive?

    I18n.t('mailers.voucher_notifications.remaining_balance', locale: locale, balance: remaining_balance_formatted, minimum: minimum_formatted)
  end
end
