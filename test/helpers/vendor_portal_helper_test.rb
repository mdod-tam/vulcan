# frozen_string_literal: true

require 'test_helper'

class VendorPortalHelperTest < ActionView::TestCase
  test 'guidance tracks W9 review separately from authorization and acceptance' do
    vendor = create(:vendor)
    assert_equal :missing_w9, vendor_onboarding_state(vendor)

    vendor.w9_form.attach(io: file_fixture('sample_w9.pdf').open, filename: 'w9.pdf', content_type: 'application/pdf')
    vendor.w9_status = :pending_review
    assert_equal :awaiting_w9_review, vendor_onboarding_state(vendor)

    vendor.w9_status = :rejected
    assert_equal :rejected_w9, vendor_onboarding_state(vendor)

    vendor.w9_status = :approved
    assert_equal :terms_unpublished, vendor_onboarding_state(vendor)

    VendorTerms.stubs(:published?).returns(true)
    VendorTerms.stubs(:agreement).returns('Test-only vendor agreement.')
    assert_equal :terms_required, vendor_onboarding_state(vendor)

    vendor.terms_accepted = '1'
    assert_equal :awaiting_authorization, vendor_onboarding_state(vendor)

    vendor.vendor_authorization_status = :approved
    assert_equal :ready, vendor_onboarding_state(vendor)

    vendor.vendor_authorization_status = :suspended
    assert_equal :suspended, vendor_onboarding_state(vendor)
  end
end
