# frozen_string_literal: true

require 'application_system_test_case'

# Storage accepting a replacement is not the server accepting it. When the server refuses a
# replacement W-9, the W-9 kept from the earlier attempt must still be there to submit.
class W9UploadRetryTest < ApplicationSystemTestCase
  setup do
    @vendor = create(:vendor, :with_w9, terms_accepted_at: 1.day.ago)
    system_test_sign_in(@vendor)
  end

  test 'a refused replacement keeps the earlier usable W-9 for the retry' do
    visit edit_vendor_portal_profile_path
    {
      business_name: 'Retry Business', business_tax_id: '123456789', website_url: 'ftp://example.com',
      physical_address_1: '42 New Street', city: 'Baltimore', state: 'MD', zip_code: '21201',
      phone: '410-555-1234', email: "retry-#{@vendor.id}@example.com"
    }.each { |field, value| fill_in "users_vendor_#{field}", with: value }
    attach_file 'Upload New W9', Rails.root.join('test/fixtures/files/sample_w9.pdf')
    click_button 'Save Changes'

    assert_text 'Website url must be a valid URL'
    assert_text I18n.t('documents.upload.uploaded', filename: 'sample_w9.pdf')
    retained = find('input[name="users_vendor[w9_form_signed_id]"]', visible: :all).value

    fill_in 'users_vendor_website_url', with: ''
    attach_file 'Upload New W9', active_content_pdf.path
    click_button 'Save Changes'

    assert_text I18n.t('documents.refused.suspicious_content')
    assert_equal retained, find('input[name="users_vendor[w9_form_signed_id]"]', visible: :all).value
    assert_text I18n.t('documents.upload.uploaded', filename: 'sample_w9.pdf')
    assert_equal 'w9.pdf', @vendor.reload.w9_form.filename.to_s

    click_button 'Save Changes'

    assert_current_path vendor_portal_dashboard_path
    assert_equal 'sample_w9.pdf', @vendor.reload.w9_form.filename.to_s
  ensure
    @active_content_pdf&.close!
  end

  private

  # Passes the browser's type and size checks; only the server's content inspection refuses it
  def active_content_pdf
    @active_content_pdf ||= Tempfile.new(['scripted_w9', '.pdf']).tap do |file|
      file.binmode
      file.write("%PDF-1.4\n/OpenAction << /S /JavaScript >>\n#{'x' * 2048}")
      file.flush
    end
  end
end
