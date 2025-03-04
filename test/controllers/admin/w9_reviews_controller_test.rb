require "test_helper"

class Admin::W9ReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create(:admin)
    @vendor = create(:vendor, :with_w9)

    # Use the fixed sign_in helper with headers
    @headers = {
      "HTTP_USER_AGENT" => "Rails Testing",
      "REMOTE_ADDR" => "127.0.0.1"
    }

    post sign_in_path,
      params: { email: @admin.email, password: "password123" },
      headers: @headers

    assert_response :redirect
    follow_redirect!
  end

  test "should get new" do
    get new_admin_vendor_w9_review_path(@vendor)
    assert_response :success
    assert_select "h1", "Review W9 Form"
  end

  test "should create approved w9 review" do
    assert_difference("W9Review.count") do
      post admin_vendor_w9_reviews_path(@vendor), params: {
        w9_review: {
          status: "approved"
        }
      }
    end

    assert_redirected_to admin_vendor_path(@vendor)
    assert_equal "W9 review completed successfully", flash[:notice]

    @vendor.reload
    assert_equal "approved", @vendor.w9_status
  end

  test "should create rejected w9 review" do
    assert_difference("W9Review.count") do
      post admin_vendor_w9_reviews_path(@vendor), params: {
        w9_review: {
          status: "rejected",
          rejection_reason_code: "address_mismatch",
          rejection_reason: "The address doesn't match our records"
        }
      }
    end

    assert_redirected_to admin_vendor_path(@vendor)
    assert_equal "W9 review completed successfully", flash[:notice]

    @vendor.reload
    assert_equal "rejected", @vendor.w9_status
  end

  test "should not create rejected w9 review without reason" do
    # First get the new page to ensure the controller sets up @w9_form
    get new_admin_vendor_w9_review_path(@vendor)
    assert_response :success

    # Then attempt to create an invalid review
    assert_no_difference("W9Review.count") do
      post admin_vendor_w9_reviews_path(@vendor), params: {
        w9_review: {
          status: "rejected",
          rejection_reason: ""
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "should show w9 review" do
    review = create(:w9_review, vendor: @vendor, admin: @admin)
    get admin_vendor_w9_review_path(@vendor, review)
    assert_response :success
  end

  test "should require admin authentication" do
    # Sign out admin
    delete sign_out_path

    get new_admin_vendor_w9_review_path(@vendor)
    assert_redirected_to sign_in_path
  end

  test "should redirect if w9 form is missing" do
    vendor_without_w9 = create(:vendor)
    get new_admin_vendor_w9_review_path(vendor_without_w9)
    assert_redirected_to admin_vendor_path(vendor_without_w9)
    assert_equal "W9 form is missing", flash[:alert]
  end

  test "should redirect if review not found" do
    get admin_vendor_w9_review_path(@vendor, 999999)
    assert_redirected_to admin_vendor_path(@vendor)
    assert_equal "Review not found", flash[:alert]
  end

  test "should redirect if vendor not found" do
    get admin_vendor_w9_review_path(999999, 1)
    assert_redirected_to admin_vendors_path
    assert_equal "Vendor not found", flash[:alert]
  end

  test "should not allow non-admin to review w9" do
    non_admin = create(:vendor)

    # Sign out admin and sign in non-admin
    delete sign_out_path

    post sign_in_path,
      params: { email: non_admin.email, password: "password123" },
      headers: @headers

    assert_response :redirect
    follow_redirect!

    get new_admin_vendor_w9_review_path(@vendor)
    assert_redirected_to root_path
    assert_equal "You are not authorized to perform this action", flash[:alert]
  end
end
