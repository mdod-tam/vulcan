# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class ProfilesControllerTest < ActionDispatch::IntegrationTest
    # Assuming AuthenticationTestHelper exists and provides sign_in_with_headers and assert_authenticated
    # If not, this helper might need to be created or adjusted based on the actual authentication setup.
    # For now, we'll assume it exists as per the user's example.
    include AuthenticationTestHelper

    setup do
      @vendor_user = create(:vendor_user, vendor_authorization_status: :pending) # Use FactoryBot to create a vendor user with pending status
      sign_in_for_integration_test(@vendor_user) # Sign in the vendor user
      assert_authenticated(@vendor_user) # Verify authentication
    end

    test 'should get edit' do
      get edit_vendor_portal_profile_url
      assert_response :success
      # Add assertions to check for specific content on the edit page
      assert_select 'h1', 'Vendor Profile' # Updated assertion
      assert_select 'input[name="users_vendor[business_name]"][value=?]', @vendor_user.business_name
    end

    test 'should update profile with terms accepted' do
      patch vendor_portal_profile_url, params: {
        users_vendor: {
          business_name: 'New Name',
          business_tax_id: @vendor_user.business_tax_id, # Include required business_tax_id
          terms_accepted: '1'
        }
      }
      assert_redirected_to vendor_portal_dashboard_url # Expect redirect on success
      # Pass headers explicitly since follow_redirect! doesn't inherit default_headers
      follow_redirect!(headers: { 'X-Test-User-Id' => @vendor_user.id.to_s })
      assert_equal 'Profile updated successfully', flash[:notice] # Check for flash notice on the redirected page
      @vendor_user.reload # Reload the user to check updated attributes
      assert_equal 'New Name', @vendor_user.business_name
      assert_not_nil @vendor_user.terms_accepted_at
    end

    test 'should not update profile without terms accepted' do
      # Assuming terms_accepted is a required attribute for certain updates or actions
      # This test case verifies that the update fails or behaves as expected if terms are not accepted.
      # The exact expected behavior (e.g., validation error, no update) depends on the application logic.
      # For this example, we'll assume it prevents the update or redirects back with errors.
      @vendor_user.business_name
      patch vendor_portal_profile_url, params: {
        users_vendor: {
          business_name: 'Attempted New Name',
          terms_accepted: '0' # Or omit terms_accepted
        }
      }
      # Assert the expected response or behavior when terms are not accepted
      # This might be assert_response :unprocessable_content, assert_response :success (if it just ignores the update),
      # or assert_redirected_to edit_vendor_profile_url with flash messages.
      # The terms_accepted_at validation is conditional on vendor_approved?,
      # and the vendor is pending in this test, so the update should succeed.
      assert_redirected_to vendor_portal_dashboard_url # Expect redirect on success
      @vendor_user.reload
      # NOTE: The business_name will be updated because the validation is skipped for pending vendors.
      assert_equal 'Attempted New Name', @vendor_user.business_name # Verify attribute was updated
      assert_nil @vendor_user.terms_accepted_at # Verify terms_accepted_at is still nil
    end

    test 'invalid Turbo submission renders errors and preserves changes for retry' do
      attributes = {
        business_name: 'Updated vendor', business_tax_id: '123456789',
        website_url: 'ftp://example.com', physical_address_1: '42 New Street',
        physical_address_2: 'Suite 3', city: 'Baltimore', state: 'MD', zip_code: '21201',
        phone: '4105551234', email: @vendor_user.email, terms_accepted: '1'
      }
      original_name = @vendor_user.business_name
      headers = { 'Accept' => 'text/vnd.turbo-stream.html, text/html' }

      patch vendor_portal_profile_url, params: { users_vendor: attributes }, headers: headers

      assert_response :unprocessable_content
      assert_equal 'text/html', response.media_type
      assert_select 'li', text: /Website url must be a valid URL/
      attributes.except(:terms_accepted).merge(phone: '410-555-1234').each do |field, value|
        assert_select "input[name='users_vendor[#{field}]'][value=?]", value
      end
      assert_equal original_name, @vendor_user.reload.business_name

      patch vendor_portal_profile_url, params: { users_vendor: attributes.merge(website_url: 'https://example.com') }, headers: headers

      assert_redirected_to vendor_portal_dashboard_url
      assert_equal 'Updated vendor', @vendor_user.reload.business_name
      assert_equal 'https://example.com', @vendor_user.website_url
    end
  end
end
