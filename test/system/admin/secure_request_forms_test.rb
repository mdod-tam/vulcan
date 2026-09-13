# frozen_string_literal: true

require 'application_system_test_case'

module AdminTests
  class SecureRequestFormsTest < ApplicationSystemTestCase
    include ProofResubmissionTestHelper

    setup do
      @admin = create(:admin)
    end

    teardown do
      Capybara.reset_sessions!
    end

    test 'secure provider info panel shows resolver channel select with only available channels' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      application.user.update!(phone_type: 'text')

      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)

      assert_selector '#secure-request-forms-title', wait: 15

      select_name = "channel_overrides[#{application.user.id}]"
      assert_selector "select[name='#{select_name}']", wait: 10
      assert_selector "select[name='#{select_name}'] option[value='email'][selected]"
      assert_selector "select[name='#{select_name}'] option[value='sms']"
      assert_selector "select[name='#{select_name}'] option[value='letter']"
      assert_no_selector "select[name='#{select_name}'] option[value='carrier_pigeon']"

      take_screenshot('secure-request-panel-channel-select', html: true)
    end

    test 'secure provider info panel disables a no-route recipient with an explanation' do
      Current.paper_context = true
      user = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      Current.paper_context = false
      user.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)

      assert_selector '#secure-request-forms-title', wait: 15
      assert_selector "input[name='recipient_ids[]'][value='#{user.id}'][disabled]", wait: 10
      assert_no_selector "select[name='channel_overrides[#{user.id}]']"
      assert_text I18n.t('admin.applications.secure_request_forms.panel.no_route')

      take_screenshot('secure-request-panel-no-route', html: true)
    ensure
      Current.reset
    end

    test 'sms-only recipient is selectable behind an explicit channel prompt and issues via sms' do
      user = build_sms_only_constituent
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)

      assert_selector '#secure-request-forms-title', wait: 15
      checkbox_selector = "input[name='recipient_ids[]'][value='#{user.id}']"
      assert_selector "#{checkbox_selector}:not([disabled])", wait: 10
      assert_no_selector "#{checkbox_selector}[checked]"
      select_selector = "#provider_info_channel_#{user.id}"
      assert_selector "#{select_selector} option[value='sms']"
      assert_no_selector "#{select_selector} option[value='sms'][selected]"

      take_screenshot('secure-request-panel-sms-only-prompt', html: true)

      check "provider_info_recipient_#{user.id}"
      find("#provider_info_channel_#{user.id} option[value='sms']").select_option
      click_button I18n.t('admin.applications.secure_request_forms.panel.submit')

      assert_text I18n.t('admin.applications.secure_request_forms.create.success'), wait: 15
      form = application.secure_request_forms.reload.order(:created_at).last
      assert_predicate form, :recipient_channel_sms?
      assert_equal user.id, form.recipient_id

      assert_selector 'table', text: I18n.t('admin.applications.secure_request_forms.channels.sms'), wait: 10
      assert_button I18n.t('admin.applications.secure_request_forms.table.resend')
      take_screenshot('secure-request-panel-sms-issued', html: true)
    ensure
      Current.reset
    end

    test 'mixed recipients submit while the unchecked sms-only dependent stays on the prompt' do
      sms_only = build_sms_only_constituent
      guardian = create(:constituent)
      # The guardian's address would otherwise provide the dependent's letter route.
      guardian.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      # The later relationship avoids automatic guardian selection and its email route.
      application = create(:application, user: sms_only, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: sms_only,
                                     relationship_type: 'Parent')

      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)

      assert_selector '#secure-request-forms-title', wait: 15
      dependent_select = "select[name='channel_overrides[#{sms_only.id}]']"
      assert_selector "#{dependent_select} option[value='']", wait: 10
      # Native required validation on this unchecked row would block the selected guardian.
      assert_no_selector "#{dependent_select}[required]"

      take_screenshot('secure-request-panel-mixed-recipients', html: true)

      check "provider_info_recipient_#{guardian.id}"
      click_button I18n.t('admin.applications.secure_request_forms.panel.submit')

      assert_text I18n.t('admin.applications.secure_request_forms.create.success'), wait: 15
      forms = application.secure_request_forms.reload
      assert_equal 1, forms.count
      assert_equal guardian.id, forms.first.recipient_id
      assert_predicate forms.first, :recipient_channel_email?

      take_screenshot('secure-request-panel-mixed-submitted', html: true)
    ensure
      Current.reset
    end

    test 'address-only recipient resolves to a preselected letter channel' do
      Current.paper_context = true
      user = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      Current.paper_context = false
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)

      assert_selector '#secure-request-forms-title', wait: 15
      select_selector = "#provider_info_channel_#{user.id}"
      assert_selector "#{select_selector} option[value='letter'][selected]", wait: 10
      assert_selector "#{select_selector} option", count: 1

      take_screenshot('secure-request-panel-address-only-letter', html: true)
    ensure
      Current.reset
    end

    test 'suspended guardian shows recipient-ineligible and owner-ineligible states together' do
      guardian = create(:constituent, email: "guardian.inel.#{SecureRandom.hex(4)}@example.com",
                                      physical_address_1: '9 Guardian Way')
      dependent = create(
        :constituent,
        email: "dependent.inel.#{SecureRandom.hex(4)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil,
                                         managing_guardian: guardian)
      guardian.update!(status: :suspended)

      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)

      assert_selector '#secure-request-forms-title', wait: 15
      # The dependent is active, but every route belongs to the suspended guardian.
      assert_selector "input[name='recipient_ids[]'][value='#{guardian.id}'][disabled]", wait: 10
      assert_selector "input[name='recipient_ids[]'][value='#{dependent.id}'][disabled]"
      assert_text I18n.t('admin.applications.secure_request_forms.panel.ineligible')
      assert_text I18n.t('admin.applications.secure_request_forms.panel.owner_ineligible')
      assert_selector "input[type='submit'][disabled][aria-disabled='true']"
      assert_text I18n.t('admin.applications.secure_request_forms.panel.submit_blocked')

      take_screenshot('secure-request-panel-ineligible-states', html: true)
    ensure
      Current.reset
    end

    test 'issued link rows name the original guardian delivery owner and its destination' do
      guardian = create(:constituent, first_name: 'Jordan', last_name: 'Example',
                                      email: "guardian.orig.#{SecureRandom.hex(4)}@example.com")
      dependent = create(
        :constituent,
        first_name: 'Riley', last_name: 'Example',
        email: "dependent.orig.#{SecureRandom.hex(4)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil,
                                         managing_guardian: guardian)

      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)

      assert_selector '#secure-request-forms-title', wait: 15
      dependent_hint = I18n.t('admin.applications.secure_request_forms.panel.destination_via',
                              owner: "#{guardian.full_name} (#{I18n.t('admin.applications.secure_request_forms.roles.guardian')}) (ID: #{guardian.id})",
                              destination: "g***@#{guardian.email.split('@', 2).last}")
      assert_selector "#provider_info_channel_#{dependent.id} option[value='email']", text: "Email — #{dependent_hint}", wait: 10
      uncheck "provider_info_recipient_#{guardian.id}"
      check "provider_info_recipient_#{dependent.id}"
      click_button I18n.t('admin.applications.secure_request_forms.panel.submit')

      assert_text I18n.t('admin.applications.secure_request_forms.create.success'), wait: 15
      form = application.secure_request_forms.reload.find_by(recipient_id: dependent.id)
      assert_equal guardian.id, form.delivery_owner_id

      assert_text I18n.t('admin.applications.secure_request_forms.table.originally_delivered_to',
                         owner: "#{guardian.full_name} (#{I18n.t('admin.applications.secure_request_forms.roles.guardian')}) (ID: #{guardian.id})")
      assert_text "(delivered to #{guardian.full_name} (#{I18n.t('admin.applications.secure_request_forms.roles.guardian')}) (ID: #{guardian.id}))"

      take_screenshot('secure-request-panel-issued-original-owner', html: true)
    ensure
      Current.reset
    end

    test 'secure request recipient workflow final evidence' do
      SmsService.stubs(:send_message).returns(true)
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      application.user.update!(phone_type: 'text')
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)
      take_screenshot('secure-request-final-entry', html: true)
      channel_id = "provider_info_channel_#{application.user_id}"
      %w[letter sms email].each do |channel|
        find("##{channel_id} option[value='#{channel}']").select_option
        assert_equal channel, find("##{channel_id}").value
        assert_no_selector "#provider_info_recipient_#{application.user_id}_destination"
        take_screenshot("secure-request-final-channel-#{channel}", html: true)
      end
      click_button I18n.t('admin.applications.secure_request_forms.panel.submit')
      assert_text I18n.t('admin.applications.secure_request_forms.create.success')
      assert_predicate application.secure_request_forms.reload.provider_info.last, :active?
      take_screenshot('secure-request-final-provider-issued', html: true)

      sms_recipient = build_sms_only_constituent
      proof_application = create(:application, :in_progress, :with_income_proof, user: sms_recipient)
      # Automatic rejection delivery has no explicit SMS selection.
      result = ProofReviewService.new(proof_application, @admin,
                                      proof_type: 'income', status: 'rejected', rejection_reason: 'Unreadable document').call
      assert_predicate result, :success?
      assert_equal false, result.data[:resubmission_delivered]
      visit_admin_application_with_retry(proof_application, user: @admin)
      assert_selector '#proof_income_request_chooser'
      assert_equal '', find("#proof_income_channel_#{sms_recipient.id}").value
      take_screenshot('secure-request-final-proof-recovery-prompt', html: true)
      within '#proof_income_request_chooser' do
        click_button 'Send Secure Income Upload Link'
      end
      assert_text I18n.t('applications.proof_resubmission.messages.no_recipient')
      assert_equal 0, proof_application.secure_request_forms.reload.count
      take_screenshot('secure-request-final-proof-empty-error', html: true)
      %w[income residency id].each do |proof_type|
        within "#proof_#{proof_type}_request_chooser" do
          check "proof_#{proof_type}_recipient_#{sms_recipient.id}"
          find("#proof_#{proof_type}_channel_#{sms_recipient.id} option[value='sms']").select_option
          take_screenshot("secure-request-final-proof-#{proof_type}-ready", html: true)
          click_button "Send Secure #{proof_type.humanize} Upload Link"
        end
        assert_selector "[data-testid='#{proof_type}-proof-secure-request-forms-panel']", text: 'SMS'
      end
      assert_equal 3, proof_application.secure_request_forms.reload.count
      take_screenshot('secure-request-final-proof-issued', html: true)

      guardian = create(:constituent, first_name: 'Casey', last_name: 'Example')
      dependent = create(:constituent, first_name: 'Casey', last_name: 'Example', dependent_email: guardian.email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      twin = create(:constituent, first_name: 'Casey', last_name: 'Example')
      create(:guardian_relationship, guardian_user: twin, dependent_user: dependent, relationship_type: 'Parent')
      household = create(:application, user: dependent, managing_guardian: guardian, status: :awaiting_proof,
                                       medical_provider_name: nil, medical_provider_phone: nil, medical_provider_email: nil)
      %i[provider_info_request id_proof_resubmission].each do |kind|
        create(:secure_request_form, application: household, recipient: dependent, kind: kind,
                                     recipient_channel: :letter, delivery_owner: guardian,
                                     delivery_source: 'managing_guardian')
      end
      guardian.update!(physical_address_1: '98 Changed Address Road')
      visit_admin_application_with_retry(household, user: @admin)
      assert_selector "label[for='provider_info_recipient_#{guardian.id}']", text: "ID: #{guardian.id}"
      assert_selector "label[for='provider_info_recipient_#{twin.id}']", text: "ID: #{twin.id}"
      within "[data-testid='id-proof-secure-request-forms-panel']" do
        assert_text 'Originally delivered to'
        assert_text "ID: #{guardian.id}"
        assert_text 'Postal mail'
        assert_no_text '98 Changed Address Road'
      end
      take_screenshot('secure-request-final-household-history', html: true)
      active_proof = household.secure_request_forms.id_proof.first
      create(:secure_request_form, :revoked, application: household, recipient: guardian,
                                             kind: :id_proof_resubmission, request_batch_id: active_proof.request_batch_id)
      create(:secure_request_form, :revoked, application: household, recipient: twin,
                                             kind: :id_proof_resubmission, request_batch_id: active_proof.request_batch_id)
      visit_admin_application_with_retry(household, user: @admin)
      within '#proof_id_request_chooser' do
        assert_selector "#proof_id_recipient_#{guardian.id}"
        assert_no_selector "#proof_id_recipient_#{dependent.id}"
        take_screenshot('secure-request-final-partial-recovery', html: true)
        click_button 'Send Secure Id Upload Link'
      end
      assert_predicate active_proof.reload, :active?
      assert_predicate household.secure_request_forms.id_proof.find_by(recipient: guardian, status: :sent), :active?
      take_screenshot('secure-request-final-partial-recovered', html: true)
      within '#proof_id_request_chooser' do
        assert_selector "#proof_id_recipient_#{twin.id}"
        assert_no_selector "#proof_id_recipient_#{guardian.id}"
        check "proof_id_recipient_#{twin.id}"
        click_button 'Send Secure Id Upload Link'
      end
      assert_predicate active_proof.reload, :active?
      assert_predicate household.secure_request_forms.id_proof.find_by(recipient: twin, status: :sent), :active?
      take_screenshot('secure-request-final-partial-all-recovered', html: true)
      guardian.update!(status: :suspended)
      twin.update!(status: :suspended)
      visit_admin_application_with_retry(household, user: @admin)
      assert_selector "#provider_info_recipient_#{dependent.id}[disabled]"
      assert_text I18n.t('admin.applications.secure_request_forms.panel.owner_ineligible')
      take_screenshot('secure-request-final-ineligible', html: true)

      Current.paper_context = true
      address_only = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      Current.reset
      postal_application = create(:application, user: address_only, status: :awaiting_proof,
                                                medical_provider_name: nil, medical_provider_phone: nil,
                                                medical_provider_email: nil)
      visit_admin_application_with_retry(postal_application, user: @admin)
      assert_equal 'letter', find("#provider_info_channel_#{address_only.id}").value
      take_screenshot('secure-request-final-address-only', html: true)
      # Direct updates model an incomplete legacy address.
      address_only.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      visit_admin_application_with_retry(postal_application, user: @admin)
      assert_selector "#provider_info_recipient_#{address_only.id}[disabled]"
      assert_text I18n.t('admin.applications.secure_request_forms.panel.no_route')
      take_screenshot('secure-request-final-no-route', html: true)
    ensure
      Current.reset
    end

    test 'Turbo proof rejection allows SMS recovery without reloading' do
      recipient = build_sms_only_constituent
      application = create(:application, :in_progress, user: recipient)
      Rails.root.join('test/fixtures/files/sample.png').open do |proof|
        application.income_proof.attach(io: proof, filename: 'income.png', content_type: 'image/png')
      end
      SmsService.expects(:send_message).with(recipient.phone, anything, sensitive: true, context: anything).once.returns(true)

      system_test_sign_in(@admin)
      visit_admin_application_with_retry(application, user: @admin)
      take_full_page_screenshot('proof-turbo-recovery-entry')
      click_review_proof_and_wait('income')
      within '#incomeProofReviewModal' do
        click_button 'Reject'
      end
      wait_for_modal_open('proofRejectionModal')
      within '#proofRejectionModal' do
        find("button[data-action='click->rejection-form#selectOther']").click
        fill_in 'Reason for Rejection', with: 'Unreadable document'
        take_full_page_screenshot('proof-turbo-recovery-rejection-modal')
        click_button 'Submit'
      end

      assert_no_selector '#proofRejectionModal[open]'
      assert_text I18n.t('admin.proof_reviews.create.resubmission_not_delivered', locale: :en)
      take_full_page_screenshot('proof-turbo-recovery-after-rejection')
      %w[income residency id].each do |proof_type|
        assert_selector "#proof_#{proof_type}_recipient_#{recipient.id}:not([disabled])"
        assert_selector "#proof_#{proof_type}_channel_#{recipient.id} option[value='sms']", visible: :all
      end
      assert_predicate application.reload, :income_proof_status_rejected?
      assert_empty application.secure_request_forms

      within '#proof_income_request_chooser' do
        check "proof_income_recipient_#{recipient.id}"
        find("#proof_income_channel_#{recipient.id} option[value='sms']").select_option
        take_full_page_screenshot('proof-turbo-recovery-sms-ready')
        click_button 'Send Secure Income Upload Link'
      end
      assert_selector "[data-testid='income-proof-secure-request-forms-panel']", text: 'SMS'
      request = application.secure_request_forms.reload.sole
      assert_equal recipient.id, request.recipient_id
      assert_equal recipient.id, request.delivery_owner_id
      assert_predicate request, :recipient_channel_sms?
      assert_predicate request, :active?
      take_full_page_screenshot('proof-turbo-recovery-issued')
    ensure
      Current.reset
    end

    private

    def take_full_page_screenshot(name)
      @screenshot_artifact_label = name
      increment_unique
      # rubocop:disable Lint/Debugger
      page.save_page(html_path)
      page.save_screenshot(image_path, full: true)
      # rubocop:enable Lint/Debugger
      write_screenshot_sidecar(image_path, label: name, html_saved: true)
      puts screenshot_log_message(image_path)
    ensure
      @screenshot_artifact_label = nil
    end

    # Paper context permits no email. Direct updates model an incomplete legacy address.
    def build_sms_only_constituent
      Current.paper_context = true
      user = create(:constituent, email: nil, phone: "555-#{rand(200..899)}-#{rand(1000..9999)}",
                                  phone_type: 'text', communication_preference: 'letter')
      Current.paper_context = false
      user.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      user
    ensure
      Current.reset
    end
  end
end
