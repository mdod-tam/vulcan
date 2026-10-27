# frozen_string_literal: true

require 'test_helper'

class VendorTermsTest < ActiveSupport::TestCase
  test 'the repository agreement starts empty and unpublished' do
    assert_not VendorTerms.published?
    assert_empty VendorTerms.agreement
    assert_not VendorTerms.available?
  end

  test 'agreement content and explicit publication are both required' do
    VendorTerms.stubs(:agreement).returns('Test-only approved agreement.')
    assert_not VendorTerms.available?

    VendorTerms.stubs(:published?).returns(true)
    assert VendorTerms.available?

    VendorTerms.stubs(:agreement).returns(" \n ")
    assert_not VendorTerms.available?
  end

  test 'a vendor rejects new acceptance while terms are unavailable' do
    vendor = build(:vendor)
    vendor.terms_accepted = '1'

    assert_not vendor.valid?
    assert_nil vendor.terms_accepted_at
    assert_includes vendor.errors[:terms_accepted], I18n.t('vendor_onboarding.terms.unavailable')
  end
end
