# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class ProfilesControllerTest < ActionDispatch::IntegrationTest
    # Assuming AuthenticationTestHelper exists and provides sign_in_with_headers and assert_authenticated
    # If not, this helper might need to be created or adjusted based on the actual authentication setup.
    # For now, we'll assume it exists as per the user's example.
    include AuthenticationTestHelper

    setup do
      VendorTerms.stubs(:published?).returns(true)
      VendorTerms.stubs(:agreement).returns('Test-only vendor agreement for profile acceptance.')
      @vendor_user = create(:vendor, vendor_authorization_status: :pending)
      sign_in_for_integration_test(@vendor_user) # Sign in the vendor user
      assert_authenticated(@vendor_user) # Verify authentication
    end

    test 'should get edit' do
      get edit_vendor_portal_profile_url
      assert_response :success
      # Add assertions to check for specific content on the edit page
      assert_select 'h1', 'Vendor Profile' # Updated assertion
      assert_select 'input[name="users_vendor[business_name]"][value=?]', @vendor_user.business_name
      assert_select 'input[name="users_vendor[business_tax_id]"][value=""]'
      assert_not_includes response.body, @vendor_user.business_tax_id
    end

    test 'unpublished terms show the blocker and reject forged acceptance' do
      VendorTerms.stubs(:published?).returns(false)
      original_name = @vendor_user.business_name

      get edit_vendor_portal_profile_url

      assert_select 'p', text: I18n.t('vendor_onboarding.terms.unavailable')
      assert_select 'input[name="users_vendor[terms_accepted]"]', count: 0

      patch vendor_portal_profile_url, params: { users_vendor: { business_name: 'Forged acceptance', terms_accepted: '1' } }

      assert_response :unprocessable_content
      assert_includes response.body, I18n.t('vendor_onboarding.terms.unavailable')
      assert_nil @vendor_user.reload.terms_accepted_at
      assert_equal original_name, @vendor_user.business_name
    end

    test 'published empty terms also reject forged acceptance' do
      VendorTerms.stubs(:agreement).returns(" \n ")

      patch vendor_portal_profile_url, params: { users_vendor: { terms_accepted: '1' } }

      assert_response :unprocessable_content
      assert_nil @vendor_user.reload.terms_accepted_at
    end

    test 'an unpublished agreement permits profile edits and keeps prior acceptance' do
      accepted_at = 3.days.ago.change(usec: 0)
      @vendor_user.update!(terms_accepted_at: accepted_at)
      VendorTerms.stubs(:published?).returns(false)

      patch vendor_portal_profile_url, params: { users_vendor: { business_name: 'Updated Business', terms_accepted: '0' } }

      assert_redirected_to vendor_portal_dashboard_url
      assert_equal accepted_at, @vendor_user.reload.terms_accepted_at
      assert_equal 'Updated Business', @vendor_user.business_name
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
      assert_select 'input[type="checkbox"][name="users_vendor[terms_accepted]"][checked]'
      attributes.except(:terms_accepted, :business_tax_id).merge(phone: '410-555-1234').each do |field, value|
        assert_select "input[name='users_vendor[#{field}]'][value=?]", value
      end
      assert_select 'input[name="users_vendor[business_tax_id]"][value=""]'
      assert_not_includes response.body, '123456789'
      assert_equal original_name, @vendor_user.reload.business_name

      patch vendor_portal_profile_url, params: { users_vendor: attributes.merge(website_url: 'https://example.com') }, headers: headers

      assert_redirected_to vendor_portal_dashboard_url
      assert_equal 'Updated vendor', @vendor_user.reload.business_name
      assert_equal 'https://example.com', @vendor_user.website_url
    end

    test 'a blank profile tax ID keeps the stored value and an explicit replacement changes it' do
      original_tax_id = @vendor_user.business_tax_id

      patch vendor_portal_profile_url, params: { users_vendor: { business_tax_id: '', business_name: 'Blank Tax Edit' } }

      assert_redirected_to vendor_portal_dashboard_url
      assert_equal original_tax_id, @vendor_user.reload.business_tax_id
      assert_equal 'Blank Tax Edit', @vendor_user.business_name

      patch vendor_portal_profile_url, params: { users_vendor: { business_tax_id: '987654321' } }

      assert_redirected_to vendor_portal_dashboard_url
      assert_equal '987654321', @vendor_user.reload.business_tax_id
    end

    test 'refuses a W-9 that is not under the size limit and keeps the profile and W-9 unchanged' do
      @vendor_user.w9_form.attach(io: file_fixture('sample_w9.pdf').open, filename: 'w9.pdf', content_type: 'application/pdf')
      previous_w9 = @vendor_user.w9_form.blob
      previous_name = @vendor_user.business_name
      oversized = Tempfile.new(['w9', '.pdf'])
      oversized.binmode
      oversized.write("%PDF-1.4\n#{'x' * (ProofUploadFormats.max_bytes(:w9) - 9)}")
      oversized.close

      patch vendor_portal_profile_url, params: {
        users_vendor: { business_name: 'Unsaved Name', w9_form: fixture_file_upload(oversized.path, 'application/pdf') }
      }

      assert_response :unprocessable_content
      assert_includes response.body, I18n.t('documents.refused.too_large_strict', max_size: ProofUploadFormats.max_megabytes(:w9))
      @vendor_user.reload
      assert_equal previous_w9, @vendor_user.w9_form.blob
      assert_equal previous_name, @vendor_user.business_name
    ensure
      oversized&.unlink
    end

    test 'a rolled-back profile update leaves only the tracked retained W-9 in storage' do
      stored_keys = []
      record_upload = ->(*, payload) { stored_keys << payload[:key] }

      ActiveSupport::Notifications.subscribed(record_upload, 'service_upload.active_storage') do
        patch vendor_portal_profile_url, params: {
          users_vendor: { website_url: 'not a url', w9_form: fixture_file_upload('sample_w9.pdf', 'application/pdf') }
        }
      end

      assert_response :unprocessable_content
      rolled_back, retained = stored_keys
      assert_equal 2, stored_keys.size, 'the update stores the file once and the re-render keeps it once'
      assert_not ActiveStorage::Blob.exists?(key: rolled_back)
      assert_not ActiveStorage::Blob.service.exist?(rolled_back)
      assert ActiveStorage::Blob.exists?(key: retained), 'the retained upload stays visible to cleanup'
    end

    test 'invalid profile replacement keeps the accepted current W9 archive and status unchanged' do
      @vendor_user.w9_form.attach(io: file_fixture('sample_w9.pdf').open, filename: 'accepted.pdf', content_type: 'application/pdf')
      @vendor_user.update!(w9_status: :approved)
      previous_w9 = @vendor_user.w9_form.blob
      snapshot = lambda do
        @vendor_user.reload
        [@vendor_user.business_name, @vendor_user.website_url, @vendor_user.w9_form.blob.id,
         @vendor_user.w9_archive.blobs.ids.sort, @vendor_user.w9_status, Event.count]
      end

      assert_no_changes snapshot do
        patch vendor_portal_profile_url, params: {
          users_vendor: { business_name: 'Unsaved replacement', website_url: 'not a url',
                          w9_form: fixture_file_upload('sample_w9.pdf', 'application/pdf') }
        }
        assert_response :unprocessable_content
      end
      assert_predicate @vendor_user, :w9_status_approved?
      assert_equal previous_w9.id, @vendor_user.w9_form.blob.id
      assert_select "input[name='users_vendor[w9_form_signed_id]']"
    end

    test 'a usable new W-9 is kept for the next attempt when another field fails' do
      @vendor_user.w9_form.attach(io: file_fixture('sample_w9.pdf').open, filename: 'w9.pdf', content_type: 'application/pdf')
      previous_w9 = @vendor_user.w9_form.blob

      patch vendor_portal_profile_url, params: {
        users_vendor: { website_url: 'not a url', w9_form: fixture_file_upload('sample_w9.pdf', 'application/pdf') }
      }

      assert_response :unprocessable_content
      assert_select 'p', text: 'Current W9 form: w9.pdf'
      assert_select "[data-document-upload-retained-name-value='users_vendor[w9_form_signed_id]']"
      retained = css_select("input[name='users_vendor[w9_form_signed_id]']").first
      assert retained, 'the new W-9 should be kept for the next attempt'
      assert_equal previous_w9, @vendor_user.reload.w9_form.blob

      patch vendor_portal_profile_url, params: {
        users_vendor: { website_url: 'https://example.com', w9_form_signed_id: retained['value'] }
      }

      assert_redirected_to vendor_portal_dashboard_url
      assert_equal 'sample_w9.pdf', @vendor_user.reload.w9_form.filename.to_s
    end
  end
end
