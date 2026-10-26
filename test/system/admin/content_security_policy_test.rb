# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ContentSecurityPolicyTest < ApplicationSystemTestCase
    setup do
      ensure_system_audit_actor!
      page.driver.browser.page.command('Page.addScriptToEvaluateOnNewDocument', source: <<~JS)
        window.parentCspViolations = [];
        document.addEventListener('securitypolicyviolation', event => {
          window.parentCspViolations.push(event.effectiveDirective);
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

    test 'application and equipment filters submit through Stimulus under the default policy' do
      visit admin_applications_path
      select 'Draft', from: 'Status:'
      assert_current_path(/status=draft/)
      select 'Current FY', from: 'Date Range:'
      assert_current_path(/date_range=current_fy/)
      check 'Show only dependent applications'
      assert_current_path(/for_minors=true/)
      assert_no_parent_violations
      take_screenshot('default-csp-application-filters', full: true, html: true)

      visit admin_reports_path
      select find('#equipment_period option[value="current_month"]').text, from: 'Period:'
      assert_current_path(/equipment_period=current_month/)
      assert_selector '#equipment-period-heading', text: Time.current.strftime('%B %Y')
      assert_no_parent_violations
      take_screenshot('default-csp-equipment-period', full: true, html: true)
    end

    test 'saved and test email previews retain inline formatting inside a script-disabled sandbox' do
      template = html_template
      [admin_email_template_path(template), new_test_email_admin_email_template_path(template)].each do |path|
        visit path
        assert_selector 'iframe.email-preview[sandbox]'
        within_frame(find('iframe.email-preview')) do
          assert_selector '#styled-preview', text: 'Styled saved body'
          assert_equal ['rgb(18, 52, 86)', 'rgb(255, 238, 221)'], preview_colors
          assert_nil page.evaluate_script('window.previewScriptRan')
        end
        assert_nil page.evaluate_script('document.body.dataset.previewCompromised')
        assert_no_parent_violations
        label = path == admin_email_template_path(template) ? 'default-csp-saved-html-preview' : 'default-csp-test-email-html-preview'
        take_screenshot(label, full: true, html: true)
      end
    end

    test 'an authenticated private PDF loads in the review iframe under the default policy' do
      vendor = create(:vendor, :with_w9)
      visit new_admin_vendor_w9_review_path(vendor)
      page.driver.clear_network_traffic
      page.execute_script(<<~JS)
        document.addEventListener('load', event => {
          if (event.target.matches?.('[data-pdf-loader-target="container"] iframe')) {
            event.target.dataset.pdfLoaded = 'true';
          }
        }, true);
      JS
      click_button 'Load PDF Preview'

      frame = find('[data-pdf-loader-target="container"] iframe[data-turbo="false"][data-pdf-loaded="true"][src]')
      assert_equal vendor_w9_document_path(vendor, vendor.w9_form.blob), URI(frame[:src]).path

      pdf_response = page.driver.network_traffic.filter_map(&:response).find do |response|
        URI(response.url).path == vendor_w9_document_path(vendor, vendor.w9_form.blob)
      end
      assert_not_nil pdf_response, 'The browser must receive the authenticated PDF response.'
      assert_equal 200, pdf_response.status
      assert_equal 'application/pdf', pdf_response.content_type
      headers = pdf_response.headers.transform_keys(&:downcase)
      assert_includes headers.fetch('content-disposition'), 'inline'
      assert_includes headers.fetch('cache-control'), 'no-store'
      assert_not_includes headers.fetch('content-security-policy', ''), 'object-src'
      assert_no_parent_violations
      take_screenshot('default-csp-private-pdf-iframe', full: true, html: true)
    end

    test 'user filters submit without inline handlers under the default policy' do
      visit admin_users_path
      select 'Constituent', from: 'Role'
      assert_current_path(/role=constituent/)
      select 'Guardians Only', from: 'Relationship'
      assert_current_path(/relationship=guardian/)
      check 'Needs Review'
      assert_current_path(/needs_review=true/)
      assert_no_parent_violations
      take_screenshot('default-csp-user-filters', full: true, html: true)
    end

    test 'secure link revocation and resend confirm before changing their records' do
      load_seeded_email_templates('application_notifications_provider_info_requested')
      vendor = create(:vendor)
      vendor_form = create(:vendor_secure_request_form, vendor: vendor)
      visit admin_vendor_path(vendor)
      within("form[action='#{admin_vendor_vendor_secure_request_form_revocation_path(vendor, vendor_form)}']") do
        dismiss_confirm { click_button I18n.t('admin.vendors.vendor_secure_request_forms.table.revoke') }
      end
      assert vendor_form.reload.active?
      within("form[action='#{admin_vendor_vendor_secure_request_form_revocation_path(vendor, vendor_form)}']") do
        accept_confirm { find_button(I18n.t('admin.vendors.vendor_secure_request_forms.table.revoke')).double_click }
      end
      assert_text I18n.t('admin.vendors.vendor_secure_request_form_revocations.create.success')
      assert vendor_form.reload.revoked?
      assert_equal 1, Event.where(auditable: vendor, action: 'w9_upload_request_revoked').count
      assert_no_parent_violations
      take_screenshot('default-csp-vendor-link-revoked', full: true, html: true)

      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil, medical_provider_email: nil)
      provider_form = create(:secure_request_form, application: application, recipient: application.user,
                                                   sent_at: (SecureFormPolicy.resend_cooldown_hours + 1).hours.ago)
      visit admin_application_path(application)
      resend_form = "form[action='#{admin_application_secure_request_forms_path(application)}']:has(input[name='resend_of_id'][value='#{provider_form.id}'])"
      within(resend_form) do
        dismiss_confirm { click_button I18n.t('admin.applications.secure_request_forms.table.resend') }
      end
      assert provider_form.reload.active?
      before_count = application.secure_request_forms.count
      within(resend_form) do
        accept_confirm { find_button(I18n.t('admin.applications.secure_request_forms.table.resend')).double_click }
      end
      assert_text I18n.t('admin.applications.secure_request_forms.create.success')
      assert provider_form.reload.revoked?
      assert_equal before_count + 1, application.secure_request_forms.count
      assert_no_parent_violations
      take_screenshot('default-csp-provider-link-resent', full: true, html: true)
    end

    test 'certification upload link asks before sending and creates one request after confirmation' do
      load_seeded_email_templates('medical_provider_request_certification')
      application = create(:application, medical_certification_status: :not_requested,
                                         medical_provider_name: 'Dr. CSP', medical_provider_email: 'provider@example.test')
      visit admin_application_path(application)
      request_path = admin_application_certification_upload_request_path(application)
      request_form = "form[action='#{request_path}']"
      confirmation = 'Send secure certification upload link to provider@example.test?'

      assert_no_difference [-> { application.medical_provider_secure_request_forms.count },
                            -> { Event.where(auditable: application, action: 'medical_certification_requested').count }] do
        within(request_form) do
          dismiss_confirm(confirmation) { click_button 'Send secure certification upload link to Dr. CSP' }
        end
      end
      assert_equal 'not_requested', application.reload.medical_certification_status
      assert_not application.medical_certification.attached?
      assert_no_parent_violations
      take_screenshot('default-csp-certification-link-dismissed', full: true, html: true)

      page.driver.clear_network_traffic
      within(request_form) do
        accept_confirm(confirmation) { find_button('Send secure certification upload link to Dr. CSP').double_click }
      end
      assert_text I18n.t('admin.applications.certification_upload_requests.create.success')
      assert_current_path admin_application_path(application)
      assert_selector 'h1#application-title', text: "Application ##{application.id}"
      assert_equal 'requested', application.reload.medical_certification_status
      request = application.medical_provider_secure_request_forms.sole
      assert_equal 'provider@example.test', request.provider_email
      assert_equal @admin.id, request.requested_by_id
      assert_equal @admin.id, Event.where(auditable: application, action: 'medical_certification_requested').sole.user_id
      assert_not application.medical_certification.attached?
      assert_equal(1, page.driver.network_traffic.count { |exchange| URI(exchange.request.url).path == request_path })
      assert_no_parent_violations
      take_screenshot('default-csp-certification-link-confirmed', full: true, html: true)
    end

    test 'certification file intake uploads a real PDF and preserves history under the default policy' do
      application = create(:application, medical_certification_status: :requested)
      fixture_path = Rails.root.join('test/fixtures/files/medical_certification_valid.pdf')
      visit admin_application_path(application)
      upload_path = upload_medical_certification_admin_application_path(application)
      assert_selector "form[action='#{upload_path}'][enctype='multipart/form-data']"
      page.driver.clear_network_traffic

      within('[data-testid="medical-certification-upload-form"]') do
        choose 'Approve Certification and Upload'
        select 'Email', from: 'Submission Method'
        attach_file 'medical_certification', fixture_path
        assert_selector '[data-scan-state="pending"]'
        assert_text I18n.t('documents.upload.scanning', filename: fixture_path.basename.to_s)
        input = find_field('medical_certification')
        assert_equal I18n.t('documents.upload.wait'), input.evaluate_script('this.validationMessage')
        assert_includes find('noscript', visible: :all).text(:all), I18n.t('documents.upload.javascript_required')
        click_button 'Process Certification'
        assert_current_path admin_application_path(application)
        assert_not application.reload.medical_certification.attached?
        assert_empty(page.driver.network_traffic.select { |exchange| URI(exchange.request.url).path == upload_path })
        take_screenshot('default-csp-certification-scan-pending', full: true, html: true)
        scan = DocumentScan.where(user: @admin, slot: 'medical_certification').sole
        scan.update!(status: :clean, completed_at: Time.current)
        assert_selector '[data-scan-state="clean"]'
        find_button('Process Certification').double_click
      end

      assert_text I18n.t('admin.applications.upload_medical_certification.c_upload_pass')
      assert_current_path admin_application_path(application)
      assert_selector 'h1#application-title', text: "Application ##{application.id}"
      assert_no_selector '[data-testid="medical-certification-upload-form"]'
      assert_selector '[data-testid="medical-certification"]', text: fixture_path.basename.to_s
      assert_equal 'approved', application.reload.medical_certification_status
      assert_equal File.binread(fixture_path), application.medical_certification.download
      history = ApplicationStatusChange.where(application: application, change_type: 'medical_certification', to_status: 'approved').sole
      assert_equal @admin.id, history.user_id
      assert_equal 'email', history.metadata.fetch('submission_method')
      assert_equal @admin.id, Event.where(auditable: application, action: 'medical_certification_status_changed').sole.user_id
      assert_equal(1, page.driver.network_traffic.count { |exchange| URI(exchange.request.url).path == upload_path })
      assert_no_parent_violations
      take_screenshot('default-csp-certification-file-approved', full: true, html: true)
    end

    test 'voucher usage renders a styled native progress control under the default policy' do
      voucher = create(:voucher, initial_value: 1000, remaining_value: 750, status: :active)
      visit admin_voucher_path(voucher)
      assert_selector 'progress[aria-label="Voucher value used"]'
      values = page.evaluate_script(<<~JS)
        (() => {
          const progress = document.querySelector('progress');
          const style = getComputedStyle(progress);
          return [progress.value, progress.max, style.appearance, style.height];
        })()
      JS
      assert_equal [25, 100, 'none', '10px'], values
      assert_no_parent_violations
      take_screenshot('default-csp-voucher-progress', full: true, html: true)
    end

    test 'HTML draft preview updates the subject and body without saving and can retry an invalid draft' do
      template = html_template
      saved_body = template.body
      spanish_template = create(:email_template, :html, name: template.name, locale: 'es', subject: 'Saved Spanish subject',
                                                        body: '<p>Saved Spanish body</p>', variables: { required: [], optional: [] }, updated_by: @admin)
      visit edit_admin_email_template_path(template)
      parent_origin = page.evaluate_script('window.location.origin')
      observe_preview_results
      within(find_by_id('body-editor-en').ancestor('form')) do
        fill_in 'Email Subject (EN)', with: 'Unsaved subject'
        find_by_id('body-editor-en').set('<p id="draft-preview" style="color: #123456;">Unsaved body</p>' \
                                         '<script>window.previewScriptRan = true; parent.document.body.dataset.previewCompromised = "yes";</script>')
        click_button 'Preview Draft'
      end
      within_frame('template-preview-en-document') do
        assert_selector 'p', text: 'Subject Preview: Unsaved subject'
        assert_selector '#draft-preview', text: 'Unsaved body'
        assert_equal 'rgb(18, 52, 86)', page.evaluate_script('getComputedStyle(document.querySelector("#draft-preview")).color')
        assert_nil page.evaluate_script('window.previewScriptRan')
        assert_equal ['null', parent_origin], page.evaluate_script('[window.origin, window.location.origin]')
      end
      assert_preview_results [false]
      assert_current_path edit_admin_email_template_path(template)
      assert_equal saved_body, template.reload.body
      assert_equal 'Saved subject', template.subject
      assert_nil page.evaluate_script('document.body.dataset.previewCompromised')
      take_screenshot('default-csp-unsaved-html-draft', full: true, html: true)

      within(find_by_id('body-editor-en').ancestor('form')) do
        find_by_id('body-editor-en').set('<p>%<not_allowed>s</p>')
        click_button 'Preview Draft'
      end
      within_frame('template-preview-en-document') do
        assert_selector '[role="alert"]', text: /Insert Variable/
        assert_equal ['null', parent_origin], page.evaluate_script('[window.origin, window.location.origin]')
      end
      assert_selector '#template-preview-en [role="alert"][aria-atomic="true"]', text: /Preview unavailable.*correct the draft/
      assert_preview_results [false, true]
      assert_selector '#body-editor-en', text: '%<not_allowed>s'
      assert_field 'Email Subject (EN)', with: 'Unsaved subject'
      within(find_by_id('body-editor-en').ancestor('form')) { click_button 'Preview Draft' }
      within_frame('template-preview-en-document') { assert_selector '[role="alert"]', text: /Insert Variable/ }
      assert_selector '#template-preview-en [role="alert"]', text: /Preview unavailable.*correct the draft/
      assert_preview_results [false, true, true]
      take_screenshot('default-csp-invalid-html-draft', full: true, html: true)
      within(find_by_id('body-editor-en').ancestor('form')) do
        fill_in 'Email Subject (EN)', with: 'Corrected subject'
        find_by_id('body-editor-en').set('<p id="retry-preview">Corrected draft</p>')
        click_button 'Preview Draft'
      end
      within_frame('template-preview-en-document') do
        assert_selector '#retry-preview', text: 'Corrected draft'
        assert_selector 'p', text: 'Subject Preview: Corrected subject'
      end
      assert_preview_results [false, true, true, false]
      assert_no_selector '#template-preview-en [role="alert"]'
      assert_equal saved_body, template.reload.body
      assert_no_parent_violations
      take_screenshot('default-csp-html-draft-retry', full: true, html: true)

      within(find_by_id('body-editor-es').ancestor('form')) do
        fill_in 'Email Subject (ES)', with: 'Nuevo asunto'
        find_by_id('body-editor-es').set('<p id="spanish-preview">Borrador nuevo</p>')
        click_button 'Preview Draft'
      end
      within_frame('template-preview-es-document') do
        assert_selector '#spanish-preview', text: 'Borrador nuevo'
        assert_selector 'p', text: 'Subject Preview: Nuevo asunto'
      end
      within_frame('template-preview-en-document') { assert_selector '#retry-preview', text: 'Corrected draft' }
      assert_equal 'Saved Spanish subject', spanish_template.reload.subject
      assert_equal '<p>Saved Spanish body</p>', spanish_template.body
      assert_no_parent_violations
      take_screenshot('default-csp-spanish-html-draft', full: true, html: true)
    end

    test 'an initial HTML srcdoc error can retry through the routed draft document' do
      template = html_template
      template.update_column(:body, '<p>%<not_allowed>s</p>')

      visit edit_admin_email_template_path(template)
      parent_origin = page.evaluate_script('window.location.origin')
      observe_preview_results
      assert_selector '#template-preview-en [role="alert"]', text: /Preview unavailable.*correct the draft/
      within_frame('template-preview-en-document') do
        assert_selector '[role="alert"]', text: /Insert Variable/
        assert_equal ['null', 'null', 'about:srcdoc'], page.evaluate_script('[window.origin, window.location.origin, window.location.href]')
      end
      assert_equal [], page.evaluate_script('window.previewResults')
      take_screenshot('default-csp-initial-html-draft-error', full: true, html: true)

      within(find_by_id('body-editor-en').ancestor('form')) do
        find_by_id('body-editor-en').set('<p id="initial-error-retry">Corrected initial draft</p>')
        click_button 'Preview Draft'
      end
      within_frame('template-preview-en-document') do
        assert_selector '#initial-error-retry', text: 'Corrected initial draft'
        assert_equal ['null', parent_origin], page.evaluate_script('[window.origin, window.location.origin]')
      end
      assert_preview_results [false]
      assert_no_selector '#template-preview-en [role="alert"]'
      assert_equal '<p>%<not_allowed>s</p>', template.reload.body
      assert_no_parent_violations
      take_screenshot('default-csp-initial-html-draft-retry', full: true, html: true)
    end

    private

    def observe_preview_results
      page.execute_script(<<~JS)
        window.previewResults = [];
        window.addEventListener('message', event => {
          if (event.data?.type !== 'mat-vulcan:email-preview') return;
          window.previewResults.push({ origin: event.origin, failed: event.data.failed,
            ownFrame: event.source === document.getElementById('template-preview-en-document').contentWindow });
          document.documentElement.dataset.previewResultCount = window.previewResults.length;
        });
      JS
    end

    def assert_preview_results(failures)
      assert_selector "html[data-preview-result-count='#{failures.length}']"
      assert_equal failures.map { |failed| { 'origin' => 'null', 'failed' => failed, 'ownFrame' => true } },
                   page.evaluate_script('window.previewResults')
    end

    def html_template
      create(:email_template, :html, subject: 'Saved subject', variables: { required: [], optional: [] }, updated_by: @admin,
                                     body: '<style>#styled-preview { color: #123456; }</style>' \
                                           '<p id="styled-preview" style="background-color: #ffeedd;">Styled saved body</p>' \
                                           '<script>window.previewScriptRan = true; parent.document.body.dataset.previewCompromised = "yes";</script>')
    end

    def preview_colors
      page.evaluate_script(<<~JS)
        (() => {
          const style = getComputedStyle(document.querySelector('#styled-preview'));
          return [style.color, style.backgroundColor];
        })()
      JS
    end

    def assert_no_parent_violations
      assert_equal [], page.evaluate_script('window.parentCspViolations')
    end
  end
end
