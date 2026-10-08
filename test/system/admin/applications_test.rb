# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ApplicationsTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      @application = create(:application, :in_progress_with_pending_proofs, skip_proofs: true)

      # The pending-proofs trait supplies income and residency files without a certification.
      unless @application.income_proof.attached?
        @application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/income_proof.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )
      end

      unless @application.residency_proof.attached?
        @application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/residency_proof.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )
      end

      unless @application.medical_certification.attached?
        @application.medical_certification.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'medical_certification_valid.pdf',
          content_type: 'application/pdf'
        )
      end

      @application.update!(medical_certification_status: :received)

      system_test_sign_in(@admin)
    end

    test 'admin can view application details successfully with factory-created records' do
      visit_admin_application_with_retry(@application, user: @admin)

      assert_selector 'h1#application-title', wait: 30
      assert_text(@application.user.full_name, wait: 20)

      assert has_selector?('[aria-labelledby="applicant-info-title"]', wait: 25)
      assert has_selector?('[aria-labelledby="application-details-title"]', wait: 25)
      assert has_selector?('[aria-labelledby="attachments-title"]', wait: 25)

      if has_selector?('[aria-labelledby="attachments-title"]', wait: 25)
        within '[aria-labelledby="attachments-title"]' do
          assert_text 'Income Proof', wait: 25
          assert_text 'Not Reviewed', wait: 25

          assert_text 'Residency Proof', wait: 25
          assert_text 'Not Reviewed', wait: 25
        end
      end
    end

    test 'admin can approve medical certification directly via service' do
      assert_equal 'received', @application.medical_certification_status

      result = MedicalCertificationAttachmentService.update_certification_status(
        application: @application,
        status: :approved,
        admin: @admin
      )

      assert result[:success], 'Medical certification approval failed'

      @application.reload
      assert_equal 'approved', @application.medical_certification_status

      with_browser_rescue do
        visit admin_application_path(@application)
        wait_for_turbo(timeout: 20)
        wait_for_network_idle(timeout: 15)

        if has_selector?('form[action="/sign_in"]', wait: 2)
          puts '=== DEBUG: Need to re-authenticate'
          system_test_sign_in(@admin)
          visit admin_application_path(@application)
          wait_for_turbo
        end

        puts "=== DEBUG: Current URL: #{current_url}"
        puts "=== DEBUG: Page title: #{page.title}"
        puts "=== DEBUG: Application user full_name: #{@application.user.full_name}"
        puts "=== DEBUG: Page has user name?: #{has_content?(@application.user.full_name, wait: 2)}"

        assert_selector 'h1#application-title', wait: 15

        assert has_content?(@application.user.full_name, wait: 25)

        assert has_selector?('h1', text: /Application.*Details/, wait: 25)

        # Try the scoped status before the broader page text.
        medical_cert_found = false

        if has_selector?('[data-testid="medical-certification-section"]', wait: 15)
          within '[data-testid="medical-certification-section"]' do
            medical_cert_found = true if has_text?('Medical Certification', wait: 10) && has_text?('Approved', wait: 10)
          end
        end

        medical_cert_found = true if !medical_cert_found && has_text?('Medical Certification', wait: 15) && has_text?('Approved', wait: 15)

        medical_cert_found = true if !medical_cert_found && has_text?('Certification', wait: 10) && has_text?('Approved', wait: 10)

        assert medical_cert_found, 'Could not find approved medical certification status on page'
      end
    end

    # Status changes only through workflow actions (Application#transition_status!), so the edit form has no status.
    test 'the edit form saves application details and offers no status control' do
      original_status = @application.status
      visit edit_admin_application_path(@application)

      assert_no_field 'Status'
      assert_no_select 'application[status]'
      fill_in 'application[medical_provider_name]', with: 'Dr. Edited'
      click_button 'Update Application'

      assert_text 'Application updated.'
      @application.reload
      assert_equal 'Dr. Edited', @application.medical_provider_name
      assert_equal original_status, @application.status
    end

    # Automatic certification requests are opt-in (dcf_auto_request_certification); see DcfAutoRequestTest.
    test 'with auto-request enabled, approving the required proofs requests the certification' do
      FeatureFlag.enable!(:dcf_auto_request_certification)
      @application.update!(
        medical_certification_status: :not_requested,
        income_proof_status: :not_reviewed,
        residency_proof_status: :not_reviewed,
        id_proof_status: :not_reviewed
      )
      attach_lightweight_proof(@application, :id_proof) unless @application.id_proof.attached?

      proof_reviewer = Applications::ProofReviewer.new(@application, @admin)

      income_result = proof_reviewer.review(
        proof_type: 'income',
        status: 'approved'
      )

      residency_result = proof_reviewer.review(
        proof_type: 'residency',
        status: 'approved'
      )

      id_result = proof_reviewer.review(proof_type: 'id', status: 'approved')

      # ProofReviewer returns true after a successful review.
      assert income_result, 'Income proof approval failed'
      assert residency_result, 'Residency proof approval failed'
      assert id_result, 'ID proof approval failed'

      @application.reload

      assert_equal 'approved', @application.income_proof_status, 'Income proof status was not approved'
      assert_equal 'approved', @application.residency_proof_status, 'Residency proof status was not approved'

      assert_equal 'requested', @application.medical_certification_status,
                   "Disability certification wasn't automatically requested after approving the required proofs"
    end
  end
end
