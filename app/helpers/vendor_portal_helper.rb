# frozen_string_literal: true

module VendorPortalHelper
  def vendor_onboarding_state(vendor)
    return :suspended if vendor.vendor_suspended?
    return :missing_w9 unless vendor.w9_form.attached?
    return :rejected_w9 if vendor.w9_status_rejected?
    return :awaiting_w9_review unless vendor.w9_status_approved?
    return :terms_unpublished unless vendor.terms_accepted_at? || VendorTerms.available?
    return :terms_required unless vendor.terms_accepted_at?
    return :awaiting_authorization unless vendor.vendor_approved?

    :ready
  end

  def vendor_onboarding_action_path(state, locale: I18n.locale)
    return edit_vendor_portal_profile_path if %i[missing_w9 rejected_w9 terms_required].include?(state)
    return vendor_portal_vouchers_path if state == :ready
    return terms_path(locale: locale) if state == :terms_unpublished

    nil
  end

  def invoice_status_badge_class(status)
    case status.to_s.downcase # Ensure consistent string comparison
    when 'pending', 'submitted'
      'bg-yellow-100 text-yellow-800'
    when 'paid', 'approved'
      'bg-green-100 text-green-800'
    when 'rejected', 'cancelled', 'void'
      'bg-red-100 text-red-800'
    when 'processing'
      'bg-blue-100 text-blue-800'
    else
      'bg-gray-100 text-gray-800' # Default for unknown statuses
    end
  end
end
