# frozen_string_literal: true

module VoucherHelper
  # Masks the voucher code, showing only the last 3 characters.
  def masked_voucher_code(code)
    return nil if code.blank?

    ('*' * (code.length - 3)) + code[-3..]
  end

  def voucher_status_badge(voucher)
    status_badge(:voucher, voucher.status, label: voucher.status.titleize, size: nil)
  end

  def voucher_transaction_status_badge(transaction)
    labels = { 'transaction_completed' => 'Completed', 'transaction_pending' => 'Pending',
               'transaction_failed' => 'Failed', 'transaction_cancelled' => 'Cancelled' }
    status_badge(:voucher_transaction, transaction.status, label: labels.fetch(transaction.status, transaction.status.titleize), size: nil)
  end

  # How a purchase's fulfillment reads to its vendor, its constituent, and staff. It says only that
  # tracking exists: a tracking number is not proof of dispatch, delivery, or acceptance, which can
  # matter to payment, and only the vendor knows whether more packages are coming.
  def fulfillment_status_label(transaction)
    return unless transaction.fulfillable?

    package_count = transaction.shipments.size
    if transaction.fulfillment_local_pickup?
      t('fulfillment.status.local_pickup')
    elsif package_count.positive?
      t('fulfillment.status.tracking_available', count: package_count)
    elsif transaction.fulfillment_shipping?
      t('fulfillment.status.awaiting_tracking')
    else
      t('fulfillment.status.awaiting_details')
    end
  end

  def purchase_date(transaction)
    l(transaction.processed_at.to_date, format: :long)
  end

  def fulfillment_status_badge(transaction)
    label = fulfillment_status_label(transaction)
    badge(label, transaction.needs_shipping_details? ? :warning : :info) if label
  end

  private

  def voucher_amount_class(amount)
    if amount >= 1000
      'text-green-600'
    elsif amount >= 500
      'text-blue-600'
    else
      'text-gray-900'
    end
  end

  # Groups a code into blocks of four: XXXX-XXXX-XXXX.
  def format_voucher_code(code)
    code.scan(/.{4}/).join('-')
  end

  def voucher_expiration_warning(voucher)
    return unless voucher.voucher_active?
    return unless voucher.expiration_date

    expiration_as_date = voucher.expiration_date.to_date
    days_until_expiry = (expiration_as_date - Date.current).to_i

    return unless days_until_expiry <= 7

    content_tag(:div, class: 'mt-1 text-sm text-danger-600') do
      if days_until_expiry <= 1
        'Expires today!'
      else
        "Expires in #{days_until_expiry} days"
      end
    end
  end

  def voucher_usage_percentage(voucher)
    return 100 if voucher.voucher_redeemed?
    return 0 if voucher.initial_value.zero?

    ((voucher.initial_value - voucher.remaining_value) / voucher.initial_value * 100).round
  end

  def voucher_usage_bar(voucher)
    percentage = voucher_usage_percentage(voucher)
    color_class = if percentage >= 90
                    '[&::-webkit-progress-value]:bg-danger-600 [&::-moz-progress-bar]:bg-danger-600'
                  elsif percentage >= 70
                    '[&::-webkit-progress-value]:bg-warning-600 [&::-moz-progress-bar]:bg-warning-600'
                  else
                    '[&::-webkit-progress-value]:bg-success-600 [&::-moz-progress-bar]:bg-success-600'
                  end

    classes = [
      'block w-full h-2.5 appearance-none overflow-hidden rounded-full border-0 bg-gray-200',
      '[&::-webkit-progress-bar]:bg-gray-200 [&::-webkit-progress-bar]:rounded-full',
      '[&::-webkit-progress-value]:rounded-full [&::-moz-progress-bar]:rounded-full',
      color_class
    ].join(' ')

    content_tag(:progress, "#{percentage}%", value: percentage, max: 100, 'aria-label': 'Voucher value used', class: classes)
  end
end
