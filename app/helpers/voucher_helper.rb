# frozen_string_literal: true

module VoucherHelper
  # Masks the voucher code, showing only the last 3 characters
  def masked_voucher_code(code)
    return nil if code.blank?

    # Keep only the last 3 characters visible
    ('*' * (code.length - 3)) + code[-3..]
  end

  def voucher_status_badge(voucher)
    case voucher.status
    when 'active'
      badge_tag('Active', :success)
    when 'expired'
      badge_tag('Expired', :danger)
    when 'redeemed'
      badge_tag('Redeemed', :info)
    when 'cancelled'
      badge_tag('Cancelled', :warning)
    else
      badge_tag(voucher.status.titleize, :default)
    end
  end

  def voucher_transaction_status_badge(transaction)
    case transaction.status
    when 'completed'
      badge_tag('Completed', :success)
    when 'pending'
      badge_tag('Pending', :warning)
    when 'failed'
      badge_tag('Failed', :danger)
    when 'cancelled'
      badge_tag('Cancelled', :warning)
    else
      badge_tag(transaction.status.titleize, :default)
    end
  end

  # How a purchase's fulfillment reads to its vendor and its constituent. Packages are counted, never
  # summed up as "shipped": only the vendor knows whether more packages are coming.
  def fulfillment_status_label(transaction)
    return unless transaction.fulfillable?

    package_count = transaction.shipments.size
    if transaction.fulfillment_local_pickup?
      t('fulfillment.status.local_pickup')
    elsif package_count.positive?
      t('fulfillment.status.packages_sent', count: package_count)
    elsif transaction.fulfillment_shipping?
      t('fulfillment.status.awaiting_tracking')
    else
      t('fulfillment.status.awaiting_details')
    end
  end

  def fulfillment_status_badge(transaction)
    label = fulfillment_status_label(transaction)
    badge_tag(label, transaction.needs_shipping_details? ? :warning : :info) if label
  end

  private

  def badge_tag(text, style)
    classes = case style
              when :success
                'bg-green-100 text-green-800'
              when :danger
                'bg-red-100 text-red-800'
              when :warning
                'bg-yellow-100 text-yellow-800'
              when :info
                'bg-blue-100 text-blue-800'
              else
                'bg-gray-100 text-gray-800'
              end

    content_tag(:span, text,
                class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{classes}")
  end

  def voucher_amount_class(amount)
    if amount >= 1000
      'text-green-600'
    elsif amount >= 500
      'text-blue-600'
    else
      'text-gray-900'
    end
  end

  def format_voucher_code(code)
    # Format as XXXX-XXXX-XXXX
    code.scan(/.{4}/).join('-')
  end

  def voucher_expiration_warning(voucher)
    return unless voucher.voucher_active?
    return unless voucher.expiration_date

    # Convert to Date objects to ensure compatible types for subtraction
    expiration_as_date = voucher.expiration_date.to_date
    days_until_expiry = (expiration_as_date - Date.current).to_i

    return unless days_until_expiry <= 7

    content_tag(:div, class: 'mt-1 text-sm text-red-600') do
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
                    'bg-red-600'
                  elsif percentage >= 70
                    'bg-yellow-600'
                  else
                    'bg-green-600'
                  end

    content_tag(:div, class: 'w-full bg-gray-200 rounded-full h-2.5') do
      content_tag(:div, '', class: "#{color_class} h-2.5 rounded-full", style: "width: #{percentage}%")
    end
  end
end
