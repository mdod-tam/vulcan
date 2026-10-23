# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'

module Admin
  class PaperUploadReferencesTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper

    setup do
      @admin = create(:admin)
      setup_fpl_policies
      system_test_sign_in(@admin)
    end

    teardown do
      @active_content_pdf&.close!
    end

    test 'a removed upload stays out of the next submission after another upload is canceled' do
      fill_complete_paper_application('Separate', 'Selections')
      cancel_staging('income_proof')

      within(upload_control('medical_certification')) do
        assert_selector 'input[type="hidden"][name="medical_certification"]', visible: :all
        click_button I18n.t('documents.upload.remove')
        assert_no_selector 'input[type="hidden"][name="medical_certification"]', visible: :all
      end
      attach_cleared_document 'income_proof', file_fixture('income_proof.pdf')

      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        assert_text 'Please upload a file for medical_certification proof before approving', wait: 20
      end
      assert_no_selector 'input[type="hidden"][name="medical_certification_signed_id"]', visible: :all
      assert_selector 'input[type="hidden"][name="income_proof"], input[type="hidden"][name="income_proof_signed_id"]', visible: :all
    end

    test 'an invalid replacement keeps the cleared upload removable and named' do
      fill_complete_paper_application('Cleared', 'Selection')
      original = certification_blob

      attach_file 'medical_certification', file_fixture('invalid.exe')
      within(upload_control('medical_certification')) do
        assert_text I18n.t('documents.refused.invalid_type', locale: :en)
        assert_text I18n.t('documents.upload.uploaded', filename: 'medical_certification_valid.pdf')
      end
      assert_equal original, certification_blob
      within(upload_control('medical_certification')) do
        click_button I18n.t('documents.upload.remove')
        assert_no_selector 'input[type="hidden"][name="medical_certification"]', visible: :all
        assert_no_button I18n.t('documents.upload.remove')
      end
    end

    test 'a server-refused replacement keeps the cleared documents ready for an unchanged submission' do
      fill_complete_paper_application('Server', 'Refusal')
      original = certification_blob
      siblings = %w[income_proof residency_proof id_proof].index_with { |key| selected_blob(key) }

      attach_file 'medical_certification', active_content_pdf.path
      within(upload_control('medical_certification')) do
        assert_text I18n.t('documents.refused.suspicious_content'), wait: 20
        assert_text I18n.t('documents.upload.uploaded', filename: original.filename.to_s)
      end
      assert_button 'Submit Paper Application', disabled: false
      assert_equal original, certification_blob
      siblings.each { |key, blob| assert_equal blob, selected_blob(key) }
      assert_empty original.attachments
      capture_upload_state('certification-staging-refused')

      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      application = Application.order(:id).last
      assert_equal original, application.medical_certification.blob
      siblings.each { |key, blob| assert_equal blob, application.public_send(key).blob }
    end

    test 'a server-retained certification survives an unchanged retry' do
      original = retained_certification_after_missing_proof('Retry')

      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      assert_equal original.id, Application.order(:id).last.medical_certification.blob.id
      capture_upload_state('retained-certification-unchanged-retry-saved')
    end

    test 'a restored certification can be replaced after a form error' do
      original = retained_certification_after_missing_proof('Replace')
      attach_cleared_document 'medical_certification', file_fixture('income_proof.pdf')

      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      certification = Application.order(:id).last.medical_certification
      assert_not_equal original.id, certification.blob.id
      assert_equal 'income_proof.pdf', certification.filename.to_s
      capture_upload_state('retained-certification-replacement-saved')
    end

    test 'a restored certification can be removed after a form error' do
      retained_certification_after_missing_proof('Remove')
      within(upload_control('medical_certification')) do
        click_button I18n.t('documents.upload.remove')
        assert_no_selector 'input[type="hidden"][name="medical_certification"], input[type="hidden"][name="medical_certification_signed_id"]', visible: :all
        assert_no_button I18n.t('documents.upload.remove')
      end

      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        assert_text 'Please upload a file for medical_certification proof before approving', wait: 20
      end
      capture_upload_state('retained-certification-removed')

      attach_cleared_document 'medical_certification', file_fixture('income_proof.pdf')
      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      assert_equal 'income_proof.pdf', Application.order(:id).last.medical_certification.filename.to_s
      capture_upload_state('retained-certification-after-remove-saved')
    end

    private

    def retained_certification_after_missing_proof(next_action)
      fill_complete_paper_application('Retained', next_action)
      original = certification_blob
      within(upload_control('income_proof')) { click_button I18n.t('documents.upload.remove') }

      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        assert_text 'Please upload a file for income proof before approving', wait: 20
      end
      assert_equal original, certification_blob
      assert_empty original.attachments
      assert_equal 0, page.evaluate_script("document.getElementById('medical_certification').files.length")
      within(upload_control('medical_certification')) do
        assert_text I18n.t('documents.upload.uploaded', filename: original.filename.to_s)
      end
      capture_upload_state("retained-certification-restored-#{next_action.downcase}")
      attach_cleared_document 'income_proof', file_fixture('income_proof.pdf')
      assert_button 'Submit Paper Application', disabled: false
      original
    end

    def capture_upload_state(label)
      take_screenshot(label, full: true, html: true)
    end

    # The browser accepts the extension and size; server byte inspection refuses the script.
    def active_content_pdf
      @active_content_pdf ||= Tempfile.new(['scripted_certification', '.pdf']).tap do |file|
        file.binmode
        file.write("%PDF-1.4\n/OpenAction << /S /JavaScript >>\n#{'x' * 2048}")
        file.flush
      end
    end

    def fill_complete_paper_application(first_name, last_name)
      visit new_admin_paper_application_path
      click_button 'Create New Applicant'
      fill_in_applicant_information(first_name: first_name, last_name: last_name,
                                    phone: "202555#{format('%04d', SecureRandom.random_number(10_000))}")
      attach_and_accept_proofs
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information
      complete_paper_application_attestations
    end

    def cancel_staging(field)
      previous_scan_id = DocumentScan.maximum(:id) || 0
      held = Queue.new
      hold_next = true
      browser = page.driver.browser
      browser.network.intercept(pattern: '*/document_scans')
      browser.on(:request) do |request|
        if hold_next
          hold_next = false
          held << request
        else
          request.continue
        end
      end
      attach_file field, file_fixture('income_proof.pdf')
      request = held.pop(timeout: 10)
      assert request, "the #{field} staging request should be held"
      within(upload_control(field)) do
        click_button I18n.t('documents.upload.cancel')
        assert_text I18n.t('documents.upload.canceled')
      end
      request.continue
      wait_until do
        DocumentScan.where(user: @admin, slot: field).where('id > ?', previous_scan_id).where.not(dismissed_at: nil).exists?
      end
    end

    def certification_blob
      selected_blob('medical_certification')
    end

    def selected_blob(field)
      within(upload_control(field)) do
        reference = find("input[type=hidden][name='#{field}'], input[type=hidden][name='#{field}_signed_id']", visible: :all).value
        ActiveStorage::Blob.find_signed!(reference)
      end
    end

    def upload_control(field)
      find_by_id(field).ancestor('[data-controller="document-upload"]')
    end
  end
end
