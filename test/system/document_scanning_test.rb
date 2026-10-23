# frozen_string_literal: true

require 'application_system_test_case'

class DocumentScanningTest < ApplicationSystemTestCase
  setup do
    ensure_system_audit_actor!
    page.driver.browser.page.command('Page.addScriptToEvaluateOnNewDocument', source: <<~JS)
      window.scanPageViolations = [];
      document.addEventListener('securitypolicyviolation', event => {
        window.scanPageViolations.push(event.effectiveDirective);
      });
    JS
    @admin = create(:admin)
    secret = ROTP::Base32.random_base32
    @admin.totp_credentials.create!(secret: secret, nickname: 'Browser authenticator')
    visit sign_in_path
    within('form[action="/sign_in"]') do
      fill_in 'contact-input', with: @admin.email
      fill_in 'password-input', with: 'password1234'
      click_button 'Sign In'
    end
    assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
    within("form[action='#{process_verification_two_factor_authentication_path(type: 'totp')}']") do
      fill_in 'code', with: ROTP::TOTP.new(secret).now
      click_button I18n.t('two_factor_verification.common.submit')
    end
    assert_current_path admin_dashboard_path
  end

  test 'a saved pending upload recovers and retries its status before publishing under CSP' do
    product = create(:product, name: 'Scan review tablet')
    visit new_admin_product_product_resource_path(product)
    fill_in 'Descriptive title (in the resource language)', with: 'Accessible setup guide'
    select 'English', from: 'Content language'
    select 'PDF document', from: 'Resource source'
    attach_file 'PDF document', Rails.root.join('test/fixtures/files/medical_certification_valid.pdf')
    assert_selector '[data-scan-state="pending"]', text: 'Checking'
    scan = DocumentScan.where(user: @admin, purpose: 'product_resource').sole
    assert scan.pending?
    assert_not scan.blob.attachments.exists?
    assert_no_difference -> { product.product_resources.count } do
      click_button 'Save public resource'
      assert_selector '[data-scan-state="pending"]'
    end
    take_screenshot('document-scan-pending-private', html: true, full: true)

    # The browser returns to the same form context after navigation or reauthentication.
    visit page.current_url
    assert_selector '[data-scan-state="pending"]', text: scan.blob.filename.to_s
    assert_equal 1, DocumentScan.where(user: @admin).count
    fill_in 'Descriptive title (in the resource language)', with: 'Accessible setup guide'
    select 'English', from: 'Content language'
    select 'External link', from: 'Resource source'
    fill_in 'External URL', with: 'https://example.org/accessible-setup'
    assert_selector '#product_resource_document:disabled'
    assert_no_selector 'input[type="hidden"][name="product_resource[document]"]:enabled', visible: :all
    assert page.evaluate_script('document.querySelector("form[action*=product_resources]").checkValidity()')
    select 'PDF document', from: 'Resource source'
    assert_selector '#product_resource_document:enabled'
    assert_selector '[data-scan-state="pending"]', text: scan.blob.filename.to_s
    assert_not page.evaluate_script('document.querySelector("form[action*=product_resources]").checkValidity()')
    page.execute_script(<<~JS, document_scan_path(scan))
      const path = arguments[0];
      const original = window.fetch.bind(window);
      window.fetch = (url, options) => {
        if (new URL(url, window.location.origin).pathname === path) {
          window.fetch = original;
          return Promise.reject(new Error('Simulated connection interruption'));
        }
        return original(url, options);
      };
    JS
    assert_selector '[data-scan-state="unavailable"]', text: I18n.t('documents.upload.unavailable')
    assert_no_selector 'input[name="product_resource[document]"][type="hidden"]', visible: :all
    take_screenshot('document-scan-status-retry', html: true, full: true)

    client = mock('attachment scanner')
    client.expects(:submit).returns(AttachmentScanner::Client::Result.new(
                                      status: 'ok', scan_id: SecureRandom.uuid, sha256: scan.sha256, byte_size: scan.blob.byte_size
                                    ))
    AttachmentScanner::Client.stubs(:new).returns(client)
    DocumentScanJob.perform_now(scan.id)
    click_button I18n.t('documents.upload.retry')
    assert_selector '[data-scan-state="clean"]', text: 'Ready:'
    assert_selector 'input[name="product_resource[document]"][type="hidden"]', visible: :all
    take_screenshot('document-scan-ready-to-submit', html: true, full: true)

    page.driver.clear_network_traffic
    find_button('Save public resource').double_click
    assert_current_path admin_product_path(product)
    assert_text 'Resource saved.'
    resource = product.product_resources.sole
    assert_equal scan.blob_id, resource.document.blob_id
    assert_equal(1, page.driver.network_traffic.count { |exchange| URI(exchange.request.url).path == admin_product_product_resources_path(product) })
    assert_equal [], page.evaluate_script('window.scanPageViolations')
    assert_equal 0, page.evaluate_script('Array.from(document.querySelectorAll("*")).flatMap(element => Array.from(element.attributes)).filter(attribute => /^on/.test(attribute.name)).length')
    take_screenshot('document-scan-published-clean', html: true, full: true)
  end
end
