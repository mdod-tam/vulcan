# frozen_string_literal: true

require 'application_system_test_case'

class ProofApprovalConfirmationTest < ApplicationSystemTestCase
  test 'proof approvals require confirmation before changing their status' do
    FeatureFlag.disable!(:vouchers_enabled)
    application = create(:application, skip_proofs: true)
    %i[income_proof residency_proof id_proof medical_certification].each do |attachment|
      application.public_send(attachment).attach(
        io: Rails.root.join('app/assets/images/TAM_color.png').open,
        filename: "#{attachment}.png", content_type: 'image/png'
      )
    end
    application.update!(medical_certification_status: :received)
    system_test_sign_in(create(:admin))
    visit admin_application_path(application)

    [
      ['incomeProofReviewModal', :income_proof_status, 'Approve income proof?'],
      ['residencyProofReviewModal', :residency_proof_status, 'Approve residency proof?'],
      ['idProofReviewModal', :id_proof_status, 'Approve ID proof?'],
      ['medicalCertificationReviewModal', :medical_certification_status, 'Approve this disability certification?']
    ].each do |modal, status_field, message|
      find("button[data-modal-id='#{modal}']").click
      assert_selector "dialog##{modal}[open]"
      before = application.reload.public_send(status_field)
      assert_equal(message, dismiss_confirm { within("##{modal}") { click_button 'Approve' } })
      assert_equal before, application.reload.public_send(status_field)
      assert_selector "dialog##{modal}[open]"
      capture("proof-confirm-cancelled-#{status_field}")

      assert_equal(message, accept_confirm { within("##{modal}") { click_button 'Approve' } })
      assert_no_selector "dialog##{modal}[open]"
      assert_equal 'approved', application.reload.public_send(status_field)
    end
    capture('proof-confirm-approvals-completed')
  end

  private

  def capture(label)
    assert_empty page.evaluate_script('window.__systemTestErrors')
    @screenshot_artifact_label = label
    increment_unique
    page.save_screenshot(image_path, full: true) # rubocop:disable Lint/Debugger -- Required proof confirmation evidence.
    File.write(image_path.sub(/\.png\z/, '.html'), page.html)
    write_screenshot_sidecar(image_path, label: label, html_saved: true)
    puts screenshot_log_message(image_path)
  ensure
    @screenshot_artifact_label = nil
  end
end
