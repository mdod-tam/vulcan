# frozen_string_literal: true

require 'application_system_test_case'

# A refused replacement must preserve the earlier cleared W-9 for the next submission.
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
    attach_cleared_document 'Upload New W9', Rails.root.join('test/fixtures/files/sample_w9.pdf')
    click_button 'Save Changes'

    assert_text 'Website url must be a valid URL'
    assert_text I18n.t('documents.upload.uploaded', filename: 'sample_w9.pdf')
    assert_selector '[data-document-upload-slot-value="w9_form"][data-scan-state="clean"]'
    retained = retained_w9
    scan = DocumentScan.find_by!(blob: retained)

    fill_in 'users_vendor_website_url', with: ''
    assert_no_difference 'DocumentScan.count' do
      attach_file 'Upload New W9', active_content_pdf.path
      assert_text I18n.t('documents.refused.suspicious_content')
    end
    assert_equal retained.id, retained_w9.id
    assert_nil scan.reload.dismissed_at
    assert_equal '', find_field('Upload New W9').value
    assert_text I18n.t('documents.upload.uploaded', filename: 'sample_w9.pdf')
    assert_equal 'w9.pdf', @vendor.reload.w9_form.filename.to_s
    take_screenshot('vendor-refused-replacement-keeps-clean-file', html: true, full: true)

    click_button 'Save Changes'

    assert_current_path vendor_portal_dashboard_path
    assert_equal retained.id, @vendor.reload.w9_form.blob.id
    assert_equal 'sample_w9.pdf', @vendor.w9_form.filename.to_s
    take_screenshot('vendor-refused-replacement-retry-saved', html: true, full: true)
  ensure
    @active_content_pdf&.close!
  end

  private

  def retained_w9
    ActiveStorage::Blob.find_signed!(find('input[data-document-upload-target="retained"]', visible: :all).value)
  end

  # Passes the browser's type and size checks; only the server's content inspection refuses it
  def active_content_pdf
    @active_content_pdf ||= Tempfile.new(['scripted_w9', '.pdf']).tap do |file|
      file.binmode
      file.write("%PDF-1.4\n/OpenAction << /S /JavaScript >>\n#{'x' * 2048}")
      file.flush
    end
  end
end
