# frozen_string_literal: true

require 'test_helper'

module Admin
  class W9ReviewsControllerTest < ActionDispatch::IntegrationTest
    setup do
      # Create a proper admin with the correct type (Administrator, not Users::Administrator)
      @admin = create(:admin)
      # NOTE: We previously removed vendor creation from setup
      sign_in_as(@admin) # Use standard helper
    end

    test 'should get new with attached w9' do
      # Create vendor with w9 attachment
      vendor = create(:vendor, type: 'Vendor')

      # Directly attach a sample file
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      assert vendor.w9_form.attached?, 'W9 form should be attached'

      # Now try to access the new page
      get new_admin_vendor_w9_review_path(vendor)

      # Since there's a W9 form attached, we should get success
      assert_response :success
      assert_select 'h1', 'Review W9 Form' if response.body.present?
    end

    test 'should create approved w9 review' do
      # Create vendor with explicit Vendor type
      vendor = create(:vendor, type: 'Vendor')
      # Attach w9_form to vendor
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/test_proof.pdf').open,
        filename: 'w9_form.pdf',
        content_type: 'application/pdf'
      )
      assert vendor.w9_form.attached? # Verify attachment

      # Clear any existing W9Reviews
      W9Review.where(vendor_id: vendor.id).destroy_all

      assert_difference('W9Review.count') do
        post admin_vendor_w9_reviews_path(vendor), params: {
          w9_review: {
            status: 'approved',
            reviewed_at: Time.current.to_s
          }
        }
      end

      assert_redirected_to admin_vendor_path(vendor)
      assert_equal 'W9 review completed successfully', flash[:notice]

      vendor.reload
      assert_equal 'approved', vendor.w9_status
    rescue ActiveSupport::TestCase::Assertion => e
      # Log the validation errors
      Rails.logger.debug { "W9Review errors: #{@controller.instance_variable_get('@w9_review')&.errors&.full_messages}" }
      raise e
    end

    test 'should create rejected w9 review' do
      # Create vendor with explicit type
      vendor = create(:vendor, type: 'Vendor')

      # Directly attach W9 form
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      assert vendor.w9_form.attached?

      # Clear any existing W9Reviews
      W9Review.where(vendor_id: vendor.id).destroy_all

      # Create the review with rejection details
      assert_difference('W9Review.count') do
        post admin_vendor_w9_reviews_path(vendor), params: {
          w9_review: {
            status: 'rejected',
            rejection_reason_code: 'address_mismatch',
            rejection_reason: "The address doesn't match our records",
            reviewed_at: Time.current.to_s
          }
        }
      end

      assert_redirected_to admin_vendor_path(vendor)
      assert_equal 'W9 review completed successfully', flash[:notice]

      vendor.reload
      assert_equal 'rejected', vendor.w9_status
    rescue ActiveSupport::TestCase::Assertion => e
      # Log the validation errors
      w9_review = @controller.instance_variable_get('@w9_review')
      if w9_review
        Rails.logger.debug { "W9Review validation errors: #{w9_review.errors.full_messages}" }
      else
        Rails.logger.debug 'W9Review instance variable is nil'
      end
      raise e
    end

    test 'should not create rejected w9 review without reason' do
      # Create vendor with explicit type
      vendor = create(:vendor, type: 'Vendor')

      # Directly attach W9 form
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      assert vendor.w9_form.attached?

      # Clear any existing W9Reviews
      W9Review.where(vendor_id: vendor.id).destroy_all

      # First get the new page to ensure the controller sets up @w9_form
      get new_admin_vendor_w9_review_path(vendor)
      assert_response :success

      # Then attempt to create an invalid review
      assert_no_difference('W9Review.count') do
        post admin_vendor_w9_reviews_path(vendor), params: {
          w9_review: {
            status: 'rejected',
            rejection_reason: '',
            rejection_reason_code: ''
          }
        }
      end

      assert_response :unprocessable_content

      # Verify we have validation errors
      w9_review = @controller.instance_variable_get('@w9_review')
      assert_not_nil w9_review, 'W9Review instance variable shouldnt be nil'
      assert w9_review.errors.any?, 'W9Review should have validation errors'
    end

    test 'should show w9 review' do
      # Create vendor with w9 attachment
      vendor = create(:vendor, type: 'Vendor')

      # Directly attach a sample file (essential for the test)
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      # Create a review for this vendor
      review = create(:w9_review, vendor: vendor, admin: @admin)

      # View the review details
      get admin_vendor_w9_review_path(vendor, review)
      assert_response :success
    end

    test 'should require admin authentication' do
      # Create vendor with explicit type
      vendor = create(:vendor, type: 'Vendor')

      # Directly attach W9 form
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      # Clear any session data
      cookies.delete(:session_token)
      # Sign out admin
      delete sign_out_path

      get new_admin_vendor_w9_review_path(vendor)
      assert_redirected_to sign_in_path
    end

    test 'should redirect if w9 form is missing even in test environment' do
      # Create vendor with explicit Vendor type but no w9
      vendor_without_w9 = create(:vendor, type: 'Vendor')

      # Confirm no W9 is attached
      assert_not vendor_without_w9.w9_form.attached?

      # Make the request in test environment
      get new_admin_vendor_w9_review_path(vendor_without_w9)

      # The logic in the controller is now correctly redirecting
      # when a w9 form is missing - so test for that instead of success
      assert_redirected_to admin_vendors_path
    end

    test 'should redirect if review not found with specific message' do
      # Create vendor with w9 attachment
      vendor = create(:vendor, type: 'Vendor')

      # Directly attach a sample file
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      # Request a non-existent review
      get admin_vendor_w9_review_path(vendor, 999_999)
      assert_redirected_to admin_vendor_path(vendor)
      assert_equal 'Review not found', flash[:alert]
    end

    test 'should redirect if vendor not found' do
      # No need to create vendor here, as the ID doesn't exist
      get admin_vendor_w9_review_path(999_999, 1)
      assert_redirected_to admin_vendors_path
      assert_equal 'Vendor not found', flash[:alert]
    end

    test 'should not allow non-admin to review w9' do
      # Create vendor with explicit type and W9
      vendor = create(:vendor, type: 'Vendor')

      # Directly attach W9 form
      vendor.w9_form.attach(
        io: Rails.root.join('test/fixtures/files/sample_w9.pdf').open,
        filename: 'w9.pdf',
        content_type: 'application/pdf'
      )

      # Create non-admin user
      non_admin = create(:vendor, type: 'Vendor')

      # Sign out admin and sign in non-admin
      delete sign_out_path
      sign_in_as(non_admin) # Use standard helper

      get new_admin_vendor_w9_review_path(vendor)
      assert_redirected_to root_path
      assert_equal 'You are not authorized to perform this action', flash[:alert]
    end
  end
end
