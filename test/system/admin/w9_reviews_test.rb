# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class W9ReviewsTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      sign_in(@admin)

      skip 'Update PDF selectors and Confirm Reject interactions before enabling W9 browser coverage'
    end

    test 'viewing vendor with pending W9' do
      vendor = create(:vendor, :with_w9)
      visit admin_vendor_path(vendor)

      assert_text 'W9 Status'
      assert_text 'Pending Review'
      assert_link 'Review W9'

      click_on 'Review W9'
      assert_current_path new_admin_vendor_w9_review_path(vendor)

      click_on 'Load PDF Preview'

      assert_selector '[data-pdf-loader-target="container"]:not(.hidden) iframe'
      assert_selector '[data-pdf-loader-target="container"]:not(.hidden) iframe[data-turbo="false"]'
      assert_selector '[data-pdf-loader-target="container"]:not(.hidden) iframe[src]'
      assert_selector '[data-pdf-loader-target="container"]:not(.hidden) iframe[data-original-src]'

      click_on 'Approve'

      assert_current_path admin_vendor_path(vendor)
      assert_text 'W9 review completed successfully'
      assert_text 'Approved'
    end

    test 'rejecting a W9 form' do
      vendor = create(:vendor, :with_w9)
      visit admin_vendor_path(vendor)
      click_on 'Review W9'

      click_on 'Load PDF Preview'
      assert_selector "iframe[data-turbo='false']"

      click_on 'Reject'
      assert_selector '.rejection-reason', visible: true

      accept_alert 'Please select a rejection reason and provide a detailed explanation' do
        click_on 'Reject'
      end
      assert_selector '.rejection-reason', visible: true

      choose 'Address Mismatch'
      fill_in 'Detailed Explanation', with: 'The address on the W9 does not match our records.'
      click_on 'Reject'

      assert_current_path admin_vendor_path(vendor)
      assert_text 'W9 review completed successfully'
      assert_text 'Rejected'

      vendor.reload
      assert_equal 'rejected', vendor.w9_status
    end

    test 'viewing W9 review details' do
      vendor = create(:vendor, :with_w9)
      review = create(:w9_review, vendor: vendor, admin: @admin, status: :approved)

      visit admin_vendor_w9_review_path(vendor, review)

      assert_selector "iframe[data-turbo='false']"
      assert_selector "iframe[type='application/pdf']"
      assert_selector 'iframe[src]'
      assert_selector 'iframe[data-original-src]'

      assert_text 'Review Details'
      assert_text 'Approved'
    end

    test 'viewing rejected W9 review details' do
      vendor = create(:vendor, :with_w9)
      review = create(:w9_review, :rejected, vendor: vendor, admin: @admin)

      visit admin_vendor_w9_review_path(vendor, review)

      assert_text 'Review Details'
      assert_text 'Rejected'
      assert_text 'Rejection Reason'
      assert_text review.rejection_reason
    end
  end
end
