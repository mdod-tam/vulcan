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
    ensure
      @active_content_pdf&.close!
    end

    private

    # Passes the browser's type and size checks; only the server's content inspection refuses it
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
