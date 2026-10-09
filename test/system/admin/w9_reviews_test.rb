# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class W9ReviewsTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      @vendor = create(:vendor, :with_w9)
      system_test_sign_in(@admin)
    end

    test 'staff preview and approve the submitted document without authorizing the vendor' do
      visit admin_vendor_path(@vendor)
      assert_text 'Pending Review'
      click_link 'Review W9'
      click_button 'Load PDF Preview'
      assert_selector '[data-pdf-loader-target="container"] iframe[data-turbo="false"][src]'
      reviewed_blob = @vendor.w9_form.blob
      click_button 'Approve'
      assert_text 'W9 review completed successfully'
      assert @vendor.reload.w9_status_approved?
      assert @vendor.vendor_pending?
      review = @vendor.w9_reviews.sole
      assert_equal reviewed_blob.id, review.reviewed_blob_id
      visit admin_vendor_w9_review_path(@vendor, review)
      assert_text 'Review Details'
      assert_selector 'iframe[title="Reviewed W9 document"][src]'
      assert_no_text 'Reviewed document unknown.'
      take_screenshot('admin-w9-approved-document-history', html: true, full: true)
    end

    test 'staff provide a reason and confirm rejection at phone width' do
      visit admin_vendor_path(@vendor)
      click_link 'Review W9'
      page.current_window.resize_to(390, 844)
      click_button 'Reject'
      assert_selector '.rejection-reason', visible: true
      assert_selector '#w9_review_rejection_reason_code_address_mismatch:focus'
      find_field('Address Mismatch').send_keys(:space)
      fill_in 'Detailed Explanation', with: 'The address on the W9 does not match our records.'
      take_screenshot('admin-w9-rejection-reason-narrow', html: true, full: true)
      click_button 'Confirm Reject'
      assert_text 'W9 review completed successfully'
      assert @vendor.reload.w9_status_rejected?
      assert_equal 1, @vendor.w9_rejections_count
      review = @vendor.w9_reviews.sole
      visit admin_vendor_w9_review_path(@vendor, review)
      assert_text 'Rejected'
      assert_text review.rejection_reason
      take_screenshot('admin-w9-rejected-history-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 800)
    end

    test 'a historical review without a document remains explicitly unknown' do
      W9Review.insert_all!([{ vendor_id: @vendor.id, admin_id: @admin.id, status: W9Review.statuses[:approved],
                              reviewed_at: 1.year.ago, created_at: 1.year.ago, updated_at: 1.year.ago }])
      review = @vendor.w9_reviews.sole
      visit admin_vendor_path(@vendor)
      assert_text 'Reviewed document unknown.'
      visit admin_vendor_w9_review_path(@vendor, review)
      assert_text 'Reviewed document unknown.'
      assert_no_selector 'iframe'
      assert_no_link 'Open in New Tab'
      take_screenshot('admin-w9-historical-document-unknown', html: true, full: true)
    end
  end
end
