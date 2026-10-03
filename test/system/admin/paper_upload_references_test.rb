# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'

module Admin
  # Rails uploads a form's files one after another and adds a hidden signed-ID input for each
  # completed one. When a later upload is canceled, the earlier one's reference stays in the form,
  # so Remove must clear it or the removed document still submits.
  class PaperUploadReferencesTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper

    setup do
      @admin = create(:admin)
      setup_fpl_policies
      system_test_sign_in(@admin)
    end

    teardown do
      @active_content_pdfs&.each_value(&:close!)
    end

    test 'a removed upload stays out of the next submission after another upload is canceled' do
      fill_complete_paper_application('Partial', 'Upload')
      held = hold_blob_requests(2)

      click_button 'Submit Paper Application'
      cancel_held_upload(held, 'income_proof')

      within(upload_control('medical_certification')) do
        assert_selector 'input[type="hidden"][name="medical_certification"]', visible: :all
        click_button I18n.t('documents.upload.remove')
        assert_no_selector 'input[type="hidden"][name="medical_certification"]', visible: :all
      end

      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        assert_text 'Please upload a file for medical_certification proof before approving', wait: 20
      end
      assert_no_selector 'input[type="hidden"][name="medical_certification_signed_id"]', visible: :all
      assert_selector 'input[type="hidden"][name="income_proof_signed_id"]', visible: :all
    end

    test 'canceling a replacement keeps the upload completed in an interrupted batch until the replacement succeeds' do
      fill_complete_paper_application('Partial', 'Replacement')
      held = hold_blob_requests(2, 3)

      # First batch: the certification completes, the income proof is canceled
      click_button 'Submit Paper Application'
      cancel_held_upload(held, 'income_proof')
      completed = certification_references
      assert_equal 1, completed.size

      # Second batch: a replacement certification is canceled before it is stored
      attach_file 'medical_certification', Rails.root.join('test/fixtures/files/income_proof.pdf')
      click_button 'Submit Paper Application'
      cancel_held_upload(held, 'medical_certification')
      assert_equal completed, certification_references

      # Third batch: the replacement succeeds and supersedes the earlier upload
      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      assert_equal 'income_proof.pdf', Application.order(:id).last.medical_certification.filename.to_s
    end

    test 'a refused replacement leaves the interrupted batch upload removable and named' do
      fill_complete_paper_application('Partial', 'Pending')
      held = hold_blob_requests(2)

      click_button 'Submit Paper Application'
      cancel_held_upload(held, 'income_proof')
      assert_equal 1, certification_references.size

      attach_file 'medical_certification', file_fixture('invalid.exe')
      within(upload_control('medical_certification')) do
        assert_text I18n.t('documents.refused.invalid_type', locale: :en)
        assert_text I18n.t('documents.upload.uploaded', filename: 'medical_certification_valid.pdf')
        click_button I18n.t('documents.upload.remove')
        assert_no_selector 'input[type="hidden"][name="medical_certification"]', visible: :all
        assert_no_button I18n.t('documents.upload.remove')
      end
    end

    test 'a replacement the server refuses falls back to the upload completed in an interrupted batch' do
      fill_complete_paper_application('Partial', 'Refusal')
      held = hold_blob_requests(2)

      # First batch: the certification completes, the income proof is canceled
      click_button 'Submit Paper Application'
      cancel_held_upload(held, 'income_proof')
      completed = certification_references
      assert_equal 1, completed.size

      # Second batch: the replacement stores, but the server refuses its content
      attach_file 'medical_certification', active_content_pdf.path
      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        assert_text "Medical certification: #{I18n.t('documents.refused.suspicious_content')}", wait: 20
      end
      assert_equal completed,
                   [find('input[type="hidden"][name="medical_certification_signed_id"]', visible: :all).value]
      within(upload_control('medical_certification')) do
        assert_text I18n.t('documents.upload.uploaded', filename: 'medical_certification_valid.pdf')
      end

      # The retry submits the earlier certification
      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      assert_equal 'medical_certification_valid.pdf', Application.order(:id).last.medical_certification.filename.to_s
    end

    test 'a server-retained certification survives interrupted replacements and an unchanged retry' do
      original = retained_certification_after_refused_replacements('Retry')

      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      assert_equal original.id, Application.order(:id).last.medical_certification.blob.id
      capture_upload_state('retained-certification-unchanged-retry-saved')
    end

    test 'a restored certification can be replaced after interrupted replacements' do
      original = retained_certification_after_refused_replacements('Replace')
      attach_file 'medical_certification', file_fixture('income_proof.pdf')

      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      certification = Application.order(:id).last.medical_certification
      assert_not_equal original.id, certification.blob.id
      assert_equal 'income_proof.pdf', certification.filename.to_s
      capture_upload_state('retained-certification-replacement-saved')
    end

    test 'a restored certification can be removed after interrupted replacements' do
      retained_certification_after_refused_replacements('Remove')
      within(upload_control('medical_certification')) do
        click_button I18n.t('documents.upload.remove')
        assert_no_selector 'input[type="hidden"]', visible: :all
        assert_no_button I18n.t('documents.upload.remove')
      end

      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        assert_text 'Please upload a file for medical_certification proof before approving', wait: 20
      end
      capture_upload_state('retained-certification-removed')

      attach_file 'medical_certification', file_fixture('income_proof.pdf')
      assert_difference 'Application.count', 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end
      assert_equal 'income_proof.pdf', Application.order(:id).last.medical_certification.filename.to_s
      capture_upload_state('retained-certification-after-remove-saved')
    end

    private

    def retained_certification_after_refused_replacements(next_action)
      fill_complete_paper_application('Retained', next_action)
      attach_file 'income_proof', active_content_pdf('refused_income').path

      # The server validates certification A while the income proof causes the form to fail.
      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        assert_text I18n.t('documents.refused.suspicious_content'), wait: 20
      end
      retained = find('input[name="medical_certification_signed_id"]', visible: :all).value
      original = ActiveStorage::Blob.find_signed!(retained)
      assert_equal 'medical_certification_valid.pdf', original.filename.to_s

      # B reaches storage, but cancellation prevents application submission and content validation.
      attach_file 'medical_certification', active_content_pdf('interrupted_certification').path
      attach_file 'income_proof', file_fixture('income_proof.pdf')
      held = hold_blob_requests(2)
      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        cancel_held_upload(held, 'income_proof')
      end
      interrupted = certification_references
      assert_equal 1, interrupted.size
      assert_not_equal retained, interrupted.first
      assert_equal retained, find('input[name="medical_certification_signed_id"]', visible: :all).value

      # C reaches storage and fails server validation. A must remain available for retry.
      attach_file 'medical_certification', active_content_pdf('refused_certification').path
      assert_no_difference 'Application.count' do
        click_button 'Submit Paper Application'
        assert_text "Medical certification: #{I18n.t('documents.refused.suspicious_content')}", wait: 20
      end
      capture_upload_state("retained-certification-restored-#{next_action.downcase}")
      assert_equal retained, find('input[name="medical_certification_signed_id"]', visible: :all).value
      assert_empty certification_references
      assert_equal 0, page.evaluate_script("document.getElementById('medical_certification').files.length")
      within(upload_control('medical_certification')) do
        assert_text I18n.t('documents.upload.uploaded', filename: original.filename.to_s)
      end
      assert_button 'Submit Paper Application', disabled: false
      original
    end

    def capture_upload_state(label)
      @screenshot_artifact_label = label
      increment_unique
      # rubocop:disable Lint/Debugger -- Persist browser evidence for the retry regression.
      page.save_screenshot(image_path, full: true)
      page.save_page(html_path)
      # rubocop:enable Lint/Debugger
      write_screenshot_sidecar(image_path, label: label, html_saved: true)
      puts screenshot_log_message(image_path)
    ensure
      @screenshot_artifact_label = nil
    end

    # Passes the browser's type and size checks; only the server's content inspection refuses it
    def active_content_pdf(label = 'scripted_certification')
      @active_content_pdfs ||= {}
      @active_content_pdfs[label] ||= Tempfile.new([label, '.pdf']).tap do |file|
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

    # Holds the blob-creation requests at the given positions (Rails uploads the certification first)
    def hold_blob_requests(*positions)
      held = Queue.new
      count = 0
      browser = page.driver.browser
      browser.network.intercept(pattern: '*/rails/active_storage/direct_uploads*')
      browser.on(:request) do |request|
        count += 1
        positions.include?(count) ? held << request : request.continue
      end
      held
    end

    def cancel_held_upload(held, field)
      request = held.pop(timeout: 10)
      assert request, "the #{field} blob request should be held"
      within(upload_control(field)) do
        click_button I18n.t('documents.upload.cancel')
        assert_text I18n.t('documents.upload.canceled')
      end
      request.continue
    rescue Ferrum::Error
      # The browser already dropped the aborted request
    end

    def certification_references
      within(upload_control('medical_certification')) do
        all('input[type="hidden"][name="medical_certification"]', visible: :all).map(&:value)
      end
    end

    def upload_control(field)
      find_by_id(field).ancestor('[data-controller="document-upload"]')
    end
  end
end
