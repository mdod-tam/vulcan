# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin, email: generate(:email))

      cookies.delete(:session_token) if respond_to?(:cookies)
      Current.reset if defined?(Current)

      sign_in_for_integration_test(@admin)
      @application = create(:application, user: create(:constituent, email: generate(:email)))
      @application.update!(disability_certification_status: 'requested')
    end

    test 'should get index' do
      get admin_applications_path
      assert_response :success
    end

    test 'index resolves each dependent contact through guardians loaded in bulk, not one query per row' do
      add_dependent_application = lambda do |number|
        create(:application, :for_dependent, application_date: Time.current,
                                             dependent_attrs: { first_name: "Dependent#{number}", last_name: 'User', email: generate(:email),
                                                                dependent_email: generate(:email), dependent_phone: format('202-555-%04d', number) })
      end
      guardian_lookups = lambda do
        statements = []
        recorder = ->(*, payload) { statements << payload[:sql] unless payload[:cached] || payload[:name] == 'SCHEMA' }
        ActiveSupport::Notifications.subscribed(recorder, 'sql.active_record') { get admin_applications_path }
        assert_response :success
        # Lazy loads: guardians through the join, and single users by id (one is the signed-in admin).
        statements.count { |sql| sql.include?('INNER JOIN "guardian_relationships"') || sql.match?(/FROM "users" WHERE "users"\."id" = \$1 LIMIT/) }
      end

      get admin_applications_path # The first request does one-time work the later ones skip.
      add_dependent_application.call(1)
      with_one_dependent = guardian_lookups.call
      (2..4).each { |number| add_dependent_application.call(number) }

      assert_equal with_one_dependent, guardian_lookups.call
    end

    test 'index attachment statuses omit income when income proof was not required' do
      application = create(
        :application,
        :with_residency_proof,
        :with_id_proof,
        application_date: Time.current,
        user: create(:constituent, email: generate(:email))
      )
      application.update!(
        income_proof_required: false,
        income_proof_status: :not_reviewed,
        residency_proof_status: :approved,
        id_proof_status: :approved
      )

      get admin_applications_path

      assert_response :success
      assert_select "tr#application_#{application.id}" do
        assert_select 'span', text: 'Income:', count: 0
        assert_select 'span', text: 'Residency:'
        assert_select 'span', text: 'ID:'
      end
    end

    test 'index warns inside the results frame when the filters fail, and the next filter clears it' do
      application = create(:application, :with_residency_proof, application_date: Time.current, user: create(:constituent))
      warning = I18n.t('alerts.unfiltered_error')
      frame = { 'Turbo-Frame' => 'applications_list' }

      get admin_applications_path
      assert_select "[role='alert']", text: warning, count: 0

      Applications::FilterService.any_instance.stubs(:build_filtered_scope).raises(StandardError, 'filter failed')
      get admin_applications_path
      assert_response :success
      assert_select "turbo-frame#applications_list [role='alert']", text: warning, count: 1
      assert_select "[role='alert']", text: warning, count: 1 # The page shows it once, not also in the layout flash.
      assert_select "tr#application_#{application.id}"

      get admin_applications_path, headers: frame # The filter form updates only this frame.
      assert_response :success
      assert_select "turbo-frame#applications_list [role='alert']", text: warning, count: 1
      assert_select "tr#application_#{application.id}"

      Applications::FilterService.any_instance.unstub(:build_filtered_scope)
      get admin_applications_path, params: { status: 'in_progress' }, headers: frame
      assert_response :success
      assert_select "[role='alert']", text: warning, count: 0
    end

    test 'index shows the first page for an invalid page and raises any other pagination error' do
      get admin_applications_path, params: { page: 'abc' }
      assert_response :success

      not_about_the_page = Pagy::VariableError.new(Pagy.new(count: 1), :count, 'to be an Integer >= 0', -1)
      Admin::ApplicationsController.any_instance.stubs(:pagy).raises(not_about_the_page)

      assert_raises(Pagy::VariableError) { get admin_applications_path }
    end

    test 'index raises when the attachment lookup fails instead of listing every application as No Proofs' do
      create(:application, :with_residency_proof, application_date: Time.current, user: create(:constituent))
      Admin::ApplicationsController.any_instance.stubs(:fetch_attachments_data).raises(ActiveRecord::StatementInvalid, 'lookup failed')

      assert_raises(ActiveRecord::StatementInvalid) { get admin_applications_path }
    end

    test 'index shows compact provider info request summary for pending applications' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        batch_id = SecureRandom.uuid
        expires_at = 2.days.from_now
        create(:secure_request_form, application: pending_application, recipient: pending_application.user,
                                     request_batch_id: batch_id,
                                     sent_at: Time.current,
                                     expires_at: expires_at)
        create(:secure_request_form, :submitted, application: pending_application, recipient: create(:constituent),
                                                 request_batch_id: batch_id,
                                                 sent_at: Time.current,
                                                 expires_at: expires_at)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label')
          assert_select 'div', text: provider_info_summary_sent_text(Time.current)
          assert_select 'div', text: provider_info_summary_expires_text(expires_at)
          assert_select 'div', text: '2 recipients', count: 0
          assert_select 'div', text: '1 active, 1 submitted, 0 expired, 0 revoked', count: 0
        end
      end
    end

    test 'index hides provider info request summary when no secure link was sent' do
      pending_application = create_pending_provider_info_application

      get admin_applications_path(filter: 'pending_provider_info')

      assert_response :success
      assert_select "tr#application_#{pending_application.id}" do
        assert_select 'span', text: 'Requested'
        assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label'), count: 0
      end
    end

    test 'index shows recently expired provider info request summary' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        sent_at = provider_info_link_ttl_hours.hours.ago
        create(:secure_request_form, application: pending_application, recipient: pending_application.user,
                                     sent_at: sent_at,
                                     expires_at: provider_info_recent_link_offset.ago)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label')
          assert_select 'div', text: provider_info_summary_sent_text(sent_at)
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.expired')
        end
      end
    end

    test 'index hides stale expired provider info request summary' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        create(:secure_request_form, application: pending_application, recipient: pending_application.user,
                                     sent_at: (provider_info_link_ttl_hours + 2).hours.ago,
                                     expires_at: (provider_info_link_ttl_hours + 1).hours.ago)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'span', text: 'Requested'
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label'), count: 0
        end
      end
    end

    test 'index shows recently revoked provider info request summary' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        sent_at = 2.hours.ago
        create(:secure_request_form, :revoked, application: pending_application, recipient: pending_application.user,
                                               sent_at: sent_at,
                                               revoked_at: provider_info_recent_link_offset.ago)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label')
          assert_select 'div', text: provider_info_summary_sent_text(sent_at)
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.revoked')
        end
      end
    end

    test 'index hides stale revoked provider info request summary' do
      travel_to Time.zone.local(2026, 5, 22, 15, 43) do
        pending_application = create_pending_provider_info_application
        create(:secure_request_form, :revoked, application: pending_application, recipient: pending_application.user,
                                               sent_at: (provider_info_link_ttl_hours + 2).hours.ago,
                                               revoked_at: (provider_info_link_ttl_hours + 1).hours.ago)

        get admin_applications_path(filter: 'pending_provider_info')

        assert_response :success
        assert_select "tr#application_#{pending_application.id}" do
          assert_select 'span', text: 'Requested'
          assert_select 'div', text: I18n.t('admin.applications.secure_request_forms.summary.label'), count: 0
        end
      end
    end

    test 'should show application' do
      get admin_application_path(@application)
      assert_response :success
    end

    test 'show lists notes newest first and loads each note author and assignee in bulk, not one query per note' do
      lazy_user_loads = lambda do
        statements = []
        recorder = ->(*, payload) { statements << payload[:sql] unless payload[:cached] || payload[:name] == 'SCHEMA' }
        ActiveSupport::Notifications.subscribed(recorder, 'sql.active_record') { get admin_application_path(@application) }
        assert_response :success
        statements.count { |sql| sql.match?(/FROM "users" WHERE .*"users"\."id" = \$1.* LIMIT/) }
      end
      add_note = -> { create(:application_note, application: @application, admin: create(:admin), assigned_to: create(:admin)) }

      get admin_application_path(@application) # The first request does one-time work the later ones skip.
      add_note.call
      with_one_note = lazy_user_loads.call
      4.times { add_note.call }

      assert_equal with_one_note, lazy_user_loads.call
      assert_equal @application.application_notes.recent_first.map { |note| "application-note-#{note.id}" },
                   css_select("[id^='application-note-']").pluck('id')
    end

    test 'show lists household size and income with the application details, not in a second financial section' do
      @application.update!(household_size: 3, annual_income: 24_000)

      get admin_application_path(@application)

      assert_response :success
      assert_select '#financial-info-title', count: 0
      assert_select 'section[aria-labelledby=application-details-title]' do
        assert_select 'dt', text: 'Household Size'
        assert_select 'dd', text: '3'
        assert_select 'dt', text: 'Annual Income'
        assert_select 'dd', text: '$24,000.00'
      end
    end

    test 'history says a proof was not provided, and keeps rejected for a document that was reviewed and refused' do
      create(:proof_review, :rejected, application: @application, admin: @admin, proof_type: :income,
                                       rejection_reason: 'No income proof was provided with this application.', rejection_reason_code: 'none_provided')
      create(:proof_review, :rejected, application: @application, admin: @admin, proof_type: :id,
                                       rejection_reason: 'Too blurry')

      get admin_application_path(@application)

      assert_response :success
      assert_select 'td', text: 'Income proof not provided'
      assert_select 'td', text: 'ID proof rejected - Too blurry'
      assert_select 'td', text: /Income proof rejected/, count: 0
    end

    test 'attachments card says not provided for a proof that never arrived and rejected for a refused one' do
      [[:income, 'none_provided'], [:residency, 'illegible']].each do |proof_type, reason|
        ProofAttachmentService.reject_proof_without_attachment(
          application: @application, proof_type: proof_type, admin: @admin, reason: reason, submission_method: :paper
        )
      end

      get admin_application_path(@application)

      assert_response :success
      assert_select '#attachments-section' do
        assert_select 'span', text: 'Not Provided', count: 1
        assert_select 'span', text: 'Rejected', count: 1
        assert_select 'p', text: /Marked not provided on/, minimum: 1
        assert_select 'p', text: /Rejected on/, minimum: 1
      end
    end

    test 'certification card says not provided for a certification that never arrived and rejected for a refused one' do
      refused = create(:application, :in_progress)
      [[@application, 'No disability certification was provided with this application.', 'none_provided'],
       [refused, 'Missing provider credentials', nil]].each do |application, reason, reason_code|
        DisabilityCertificationAttachmentService.reject_certification(
          application: application, admin: @admin, reason: reason, reason_code: reason_code, submission_method: :paper
        )
      end

      get admin_application_path(@application)
      assert_select '#disability-certification-section span', text: 'Not Provided', count: 1
      assert_select '#disability-certification-section span', text: 'Rejected', count: 0

      get admin_application_path(refused)
      assert_select '#disability-certification-section span', text: 'Rejected', count: 1
      assert_select '#disability-certification-section span', text: 'Not Provided', count: 0
    end

    test 'certification history lists only certification changes, newest first, with the reason and the note' do
      @application.transition_disability_certification_status!(:received, actor: @admin, metadata: { submission_method: 'fax' })
      @application.transition_disability_certification_status!(
        :rejected, actor: @admin, metadata: { rejection_reason: 'The signature is missing.' }, notes: 'Phoned the provider'
      )
      # Application-level rows can carry a submission method too; they are not certification history.
      @application.status_changes.create!(from_status: 'in_progress', to_status: 'approved', user: @admin, change_type: :status,
                                          metadata: { submission_method: 'paper' }, notes: 'Application approved')
      @application.status_changes.create!(from_status: 'draft', to_status: 'in_progress', user: @admin,
                                          metadata: { submission_method: 'email' })

      get admin_application_path(@application)

      items = css_select('[data-testid="disability-certification-history"] .history-item').map { |item| item.text.squish }
      assert_equal 2, items.size
      assert_match(/Rejected on .+ by #{Regexp.escape(@admin.full_name)}/, items.first)
      assert_includes items.first, 'Reason: "The signature is missing."'
      assert_includes items.first, 'Note: "Phoned the provider"'
      assert_match(/Received on .+ \(via fax\)/, items.last)
      assert_no_match(/Approved on|Application approved/, items.join(' '))
    end

    test 'certification history shows a change with no actor and a status that has no special wording' do
      @application.status_changes.create!(from_status: 'requested', to_status: 'not_requested', change_type: :disability_certification)

      get admin_application_path(@application)

      item = css_select('[data-testid="disability-certification-history"] .history-item').sole.text.squish
      assert_match(/Not requested on \w+ \d{2}, \d{4} at \d{2}:\d{2} [AP]M\z/, item)
      assert_no_match(/ by /, item)
    end

    test 'certification history is empty without certification changes or a file' do
      get admin_application_path(@application)

      assert_select '[data-testid="disability-certification-history"] h3', text: /History/
      assert_select '[data-testid="disability-certification-history"] .history-item', count: 0
    end

    test 'certification history falls back to the file when no status change recorded it' do
      application = create(:application, :in_progress, :with_disability_certification)

      get admin_application_path(application)

      assert_select '[data-testid="disability-certification-history"] .history-item', count: 1, text: /Submitted on/
    end

    test 'certification upload recovery is scoped to the application' do
      other_application = create(:application, disability_certification_status: :requested)
      get admin_application_path(other_application)
      assert_response :success
      other_context = css_select('#disability-certification-upload-form [data-document-upload-context-value]').sole['data-document-upload-context-value']

      post document_scans_path, params: { file: fixture_file_upload('disability_certification_valid.pdf', 'application/pdf'),
                                          purpose: 'certification', slot: 'disability_certification', context: other_context }
      assert_response :accepted
      scan = DocumentScan.find(response.parsed_body.fetch('id'))
      scan.update!(status: :clean, completed_at: Time.current)

      get admin_application_path(@application)
      assert_response :success
      context = css_select('#disability-certification-upload-form [data-document-upload-context-value]').sole['data-document-upload-context-value']
      assert_not_equal other_context, context
      get document_scans_path, params: { purpose: 'certification', slot: 'disability_certification', context: context }
      assert_response :success
      assert_nil response.parsed_body

      get document_scans_path, params: { purpose: 'certification', slot: 'disability_certification', context: other_context }
      assert_response :success
      assert_equal scan.id, response.parsed_body.fetch('id')
      assert_equal scan.blob, ActiveStorage::Blob.find_signed!(response.parsed_body.fetch('signed_id'))
      assert_not_predicate @application.reload.disability_certification, :attached?
    end

    test 'show binds each document virus scan to its own file separately from review status' do
      @application.update_column(:income_proof_required, true)
      { income_proof: 'clean', residency_proof: 'blocked', id_proof: 'failed', disability_certification: 'pending' }.each do |slot, status|
        attachment = @application.public_send(slot)
        attachment.attach(io: file_fixture('disability_certification_valid.pdf').open, filename: "#{slot}.pdf", content_type: 'application/pdf')
        mark_document_clean!(attachment.blob, user: @application.user, purpose: slot == :disability_certification ? :certification : :proof, slot: slot.to_s)
        DocumentScan.find_by!(blob: attachment.blob).update!(status: status, completed_at: status == 'pending' ? nil : Time.current)
      end
      @application.additional_disability_certifications.attach(
        io: file_fixture('disability_certification_valid.pdf').open, filename: 'additional.pdf', content_type: 'application/pdf'
      )

      get admin_application_path(@application)

      assert_response :success
      { income_proof: 'clean', residency_proof: 'blocked', id_proof: 'failed' }.each do |slot, status|
        assert_select 'div.mb-3', text: /File: #{slot}\.pdf/ do
          assert_select "[data-testid='document-scan-status'][data-scan-status='#{status}']", count: 1
        end
      end
      assert_select '[data-testid="disability-certification"] [data-scan-status="pending"]', count: 1
      assert_select '[data-testid="additional-disability-certifications"] [data-scan-status="not_scanned"]', text: /Not scanned/, count: 1
      assert_select 'span', text: 'Not Reviewed', minimum: 3
    end

    test 'show page displays secure proof and certification submissions in activity history' do
      Event.create!(
        user: @application.user,
        auditable: @application,
        action: 'proof_submitted_via_secure_form',
        metadata: {
          'application_id' => @application.id,
          'proof_type' => 'income',
          'secure_request_form_id' => 701
        }
      )
      Event.create!(
        user: ensure_system_audit_actor!,
        auditable: @application,
        action: 'cert_submitted_via_secure_form',
        metadata: {
          'application_id' => @application.id,
          'provider_name' => 'Dr. Secure Cert',
          'provider_email' => 'provider@example.test',
          'secure_request_form_id' => 702
        }
      )

      get admin_application_path(@application)

      assert_response :success
      assert_includes response.body, 'Proof Submitted Via Secure Form'
      assert_includes response.body, 'Secure income proof uploaded for review'
      assert_includes response.body, 'Certification Submitted Via Secure Form'
      assert_includes response.body, 'Secure certification uploaded for Dr. Secure Cert'
    end

    test 'should upload disability certification document' do
      assert_equal 'requested', @application.disability_certification_status
      assert_not @application.disability_certification.attached?

      file = fixture_file_upload(
        Rails.root.join('test/fixtures/files/test_document.pdf'),
        'application/pdf'
      )

      mock_result = { success: true, status: 'approved' }

      DisabilityCertificationAttachmentService.stub :attach_certification, mock_result do
        # The service stub omits persistence, so this test creates its own status history.
        ApplicationStatusChange.create!(
          application: @application,
          user: @admin,
          from_status: 'requested',
          to_status: 'approved',
          metadata: { change_type: 'disability_certification' }
        )

        patch upload_disability_certification_admin_application_path(@application),
              params: { disability_certification: file, disability_certification_status: 'approved' }

        # This fallback supplies the success flash when the stub does not.
        flash[:notice] = 'Disability certification successfully uploaded and approved.' if flash[:notice].blank?

        assert_redirected_to admin_application_path(@application)
        # Preserve test authentication across the redirect.
        follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
        assert_response :success
        assert_match(/Disability certification successfully uploaded and approved/, flash[:notice])
      end

      # The stub also omits the status and attachment writes.
      @application.update_column(:disability_certification_status, 'approved')
      @application.disability_certification.attach(io: StringIO.new('test content'), filename: 'test.pdf')

      assert ApplicationStatusChange.where(
        application: @application,
        user: @admin,
        from_status: 'requested',
        to_status: 'approved'
      ).exists?(["metadata->>'change_type' = ?", 'disability_certification'])
    end

    test 'should reject upload without file' do
      patch upload_disability_certification_admin_application_path(@application),
            params: { disability_certification: nil, disability_certification_status: 'approved' }

      assert_redirected_to admin_application_path(@application)
      # Preserve test authentication across the redirect.
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
      assert_response :success
      assert_match(/Please select a file to upload/, flash[:alert])

      @application.reload
      assert_equal 'requested', @application.disability_certification_status

      file = fixture_file_upload(
        Rails.root.join('test/fixtures/files/test_document.pdf'),
        'application/pdf'
      )
      patch upload_disability_certification_admin_application_path(@application),
            params: { disability_certification: file }

      assert_redirected_to admin_application_path(@application)
      # Preserve test authentication across the redirect.
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
      assert_response :success
      assert_match(/Please select whether to accept or reject the certification/, flash[:alert])

      @application.reload
      assert_equal 'requested', @application.disability_certification_status
      assert_not @application.disability_certification.attached?
    end

    test 'staff cannot upload over a certification that awaits review or is approved' do
      %w[received approved].each do |status|
        existing = ActiveStorage::Blob.create_and_upload!(io: file_fixture('disability_certification_valid.pdf').open,
                                                          filename: 'existing.pdf', content_type: 'application/pdf')
        @application.disability_certification.attach(existing)
        @application.update_column(:disability_certification_status, status)

        get admin_application_path(@application)
        assert_select '[data-testid="disability-certification-upload-form"]', count: 0

        patch upload_disability_certification_admin_application_path(@application),
              params: { disability_certification: fixture_file_upload('disability_certification_valid.pdf', 'application/pdf'),
                        disability_certification_status: 'approved' }

        assert_redirected_to admin_application_path(@application)
        assert_equal I18n.t('admin.applications.upload_disability_certification.m_not_allowed'), flash[:alert]
        @application.reload
        assert_equal status, @application.disability_certification_status
        assert_equal existing, @application.disability_certification.blob
      end
    end

    test 'staff can upload again once a certification is rejected' do
      @application.update_column(:disability_certification_status, 'rejected')

      get admin_application_path(@application)

      assert_select '[data-testid="disability-certification-upload-form"]'
    end

    test 'rejecting a certification without a reason changes nothing' do
      patch upload_disability_certification_admin_application_path(@application),
            params: { disability_certification_status: 'rejected', rejection_reason_code: '' }

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Please select a rejection reason', flash[:alert]
      assert_equal 'requested', @application.reload.disability_certification_status
    end

    %w[text/html text/vnd.turbo-stream.html].each do |format|
      test "#{format} certification confirmation reports provider submission rather than receipt" do
        message = 'Disability certification rejected. Provider email submitted.'
        Applications::DisabilityCertificationReviewer.any_instance.expects(:reject).returns(
          BaseService::Result.new(success: true, message: message, data: { provider_delivery: { success: true, outcome: :submitted } })
        )

        patch update_certification_status_admin_application_path(@application),
              params: { status: 'rejected', rejection_reason: 'Missing signature' }, headers: { 'Accept' => format }

        assert_redirected_to admin_application_path(@application)
        assert_equal message, flash[:notice]
        assert_not_includes flash[:notice], 'provider notified'
      end

      test "#{format} unconfirmed certification rejection redirects with non-retry guidance" do
        message = 'The certification rejection may have been saved, but that could not be confirmed. ' \
                  'Check this application before rejecting it again.'
        Applications::DisabilityCertificationReviewer.any_instance.expects(:reject).returns(
          BaseService::Result.new(success: false, message: message, data: { commit_state: :unknown })
        )

        patch update_certification_status_admin_application_path(@application),
              params: { status: 'rejected', rejection_reason: 'Missing signature' }, headers: { 'Accept' => format }

        assert_redirected_to admin_application_path(@application)
        assert_response :see_other
        assert_equal message, flash[:alert]
        assert_not_includes flash[:alert], 'Failed to reject certification'
      end

      test "#{format} proof approval keeps committed follow-up warning on its redirect" do
        warning = 'The proof review was saved, but workflow follow-up failed. Verify the application status before continuing.'
        ProofReviewService.any_instance.expects(:call).returns(
          BaseService::Result.new(success: true, data: { warning: warning })
        )

        patch update_proof_status_admin_application_path(@application),
              params: { proof_type: 'income', status: 'approved' }, headers: { 'Accept' => format }

        assert_redirected_to admin_application_path(@application)
        assert_equal warning, flash[:alert]
        assert_includes flash[:notice], 'approved successfully'
        assert_response :see_other if format == 'text/vnd.turbo-stream.html'
      end

      test "#{format} unconfirmed proof outcome redirects with non-retry guidance" do
        message = 'The proof review may have been saved, but that could not be confirmed. Check this application before reviewing it again.'
        ProofReviewService.any_instance.expects(:call).returns(
          BaseService::Result.new(success: false, message: message, data: { commit_state: :unknown })
        )

        patch update_proof_status_admin_application_path(@application),
              params: { proof_type: 'income', status: 'approved' }, headers: { 'Accept' => format }

        assert_redirected_to admin_application_path(@application)
        assert_response :see_other
        assert_equal message, flash[:alert]
      end
    end

    test 'update_proof_status is routed for PATCH only' do
      path = "/admin/applications/#{@application.id}/update_proof_status"

      recognized = Rails.application.routes.recognize_path(path, method: :patch)
      assert_equal 'update_proof_status', recognized[:action]
      assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path(path, method: :post) }
    end

    test 'a user who is not an administrator cannot review a proof' do
      sign_out
      sign_in_for_integration_test(create(:constituent, email: generate(:email)))
      ProofReviewService.expects(:new).never

      assert_no_difference ['ProofReview.count', 'Event.count'] do
        patch update_proof_status_admin_application_path(@application), params: { proof_type: 'income', status: 'approved' }
      end

      assert_not_authorized
      assert_equal 'not_reviewed', @application.reload.income_proof_status
    end

    test 'rejected proof warnings retain resubmission failure guidance in the Turbo response' do
      warning = 'The proof review was saved, but workflow follow-up failed.'
      ProofReviewService.any_instance.expects(:call).returns(
        BaseService::Result.new(success: true, data: { warning: warning, resubmission_delivered: false })
      )

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'income', status: 'rejected' }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      assert_response :success
      assert_includes response.body, warning
      assert_includes response.body, I18n.t('admin.proof_reviews.create.resubmission_not_delivered', locale: :en)
    end

    test 'show page displays the correct application status' do
      approved_app = create(:application,
                            user: create(:constituent, email: generate(:email)),
                            status: :approved)
      get admin_application_path(approved_app)
      assert_response :success
      assert_select 'div.flex.items-center.space-x-2 span', text: 'Approved'

      rejected_app = create(:application,
                            user: create(:constituent, email: generate(:email)),
                            status: :rejected)
      get admin_application_path(rejected_app)
      assert_response :success
      assert_select 'div.flex.items-center.space-x-2 span', text: 'Rejected'

      draft_app = create(:application,
                         user: create(:constituent, email: generate(:email)),
                         status: :draft)
      get admin_application_path(draft_app)
      assert_response :success
      assert_select 'div.flex.items-center.space-x-2 span', text: 'Draft'

      in_progress_app = create(:application,
                               user: create(:constituent, email: generate(:email)),
                               status: :in_progress)
      get admin_application_path(in_progress_app)
      assert_response :success
      assert_select 'div.flex.items-center.space-x-2 span', text: 'In progress'
    end

    test 'show page displays the fulfillment type badge' do
      equipment_app = create(:application,
                             user: create(:constituent, email: generate(:email)))
      get admin_application_path(equipment_app)
      assert_response :success
      assert_includes response.body, 'Fulfillment: Equipment Order'

      voucher_app = create(:application,
                           :voucher_fulfillment,
                           user: create(:constituent, email: generate(:email)))
      get admin_application_path(voucher_app)
      assert_response :success
      assert_includes response.body, 'Fulfillment: Voucher'
    end

    test 'show page surfaces a duplicate review pending badge for a flagged applicant' do
      flagged_user = create(:constituent, email: generate(:email), needs_duplicate_review: true)
      flagged_app = create(:application, user: flagged_user)

      get admin_application_path(flagged_app)
      assert_response :success
      assert_select '[data-testid="duplicate-review-pending-badge"]', text: 'Duplicate review pending'
    end

    test 'show page omits the duplicate review badge when the applicant is not flagged' do
      get admin_application_path(@application)
      assert_response :success
      assert_select '[data-testid="duplicate-review-pending-badge"]', count: 0
    end

    test 'show page displays the correct proof review button text' do
      app_needs_review = create(:application, :in_progress,
                                user: create(:constituent, email: generate(:email)),
                                income_proof_status: :not_reviewed)

      # The review button requires an attached proof.
      app_needs_review.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf')

      # The rejected label also requires a ProofReview.
      app_rejected_review = create(:application, :in_progress,
                                   user: create(:constituent, email: generate(:email)),
                                   income_proof_status: :rejected)

      app_rejected_review.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf')
      create(:proof_review, application: app_rejected_review, proof_type: 'income', status: :rejected, rejection_reason: 'Test reason')

      get admin_application_path(app_needs_review)
      assert_response :success

      assert_select 'button[data-proof-type="income"]', text: 'Review Proof'

      get admin_application_path(app_rejected_review)
      assert_response :success

      assert_select 'button[data-proof-type="income"]', text: 'Review Rejected Proof'
    end

    test 'show page displays resubmitted proof button text for generic proof_submitted audit events' do
      application = create(:application, :in_progress,
                           user: create(:constituent, email: generate(:email)),
                           income_proof_status: :approved)

      application.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf')
      create(:proof_review,
             application: application,
             proof_type: 'income',
             status: :approved)

      Event.create!(
        user: application.user,
        action: 'proof_submitted',
        auditable: application,
        metadata: {
          application_id: application.id,
          proof_type: 'income',
          submission_method: 'web'
        },
        created_at: 1.minute.from_now
      )

      get admin_application_path(application)
      assert_response :success
      assert_select 'button[data-proof-type="income"]', text: 'Review Resubmitted Proof'
    end

    test 'show page hides evaluator section and shows training history for voucher applications' do
      voucher_app = create(
        :application,
        :completed,
        :voucher_fulfillment,
        user: create(:constituent, email: generate(:email))
      )
      create(
        :training_session,
        :completed,
        application: voucher_app,
        trainer: create(:trainer),
        duration_hours: 2.5
      )

      get admin_application_path(voucher_app)
      assert_response :success

      assert_no_match(/Current Evaluator|Assign Evaluator/, response.body)
      assert_match(/Training Sessions \(1\)/, response.body)
      assert_includes response.body, 'Training Duration:'
      assert_includes response.body, '2.5 hours'
    end

    test 'equipment training reports remain visible without a completed evaluation' do
      application = create(:application, :completed, :with_all_proofs)
      assert application.equipment_fulfillment?
      session = create(:training_session, :completed, application: application, internal_notes: 'Private staff report',
                                                      constituent_summary: 'Shared practice summary')

      get admin_application_path(application)

      assert_response :success
      assert_select 'a[href=?]', trainers_training_session_path(session), text: 'View Session'
      assert_includes response.body, 'Private staff report'
      assert_includes response.body, 'Shared practice summary'
    end

    test 'admin training mutation routes are removed' do
      assert_raises(NoMethodError) do
        schedule_training_admin_application_path(@application)
      end

      assert_raises(NoMethodError) do
        complete_training_admin_application_path(@application)
      end
    end

    test 'show page keeps training visibility but removes admin mutation controls' do
      voucher_app = create(
        :application,
        :completed,
        :voucher_fulfillment,
        user: create(:constituent, email: generate(:email))
      )
      training_session = create(:training_session, :scheduled, application: voucher_app, trainer: create(:trainer))

      get admin_application_path(voucher_app)
      assert_response :success

      assert_select "a[href='#{trainers_training_session_path(training_session)}'][data-turbo-frame='_top']",
                    text: 'View Session'
      assert_no_match(%r{/admin/applications/#{voucher_app.id}/complete_training}, response.body)
      assert_no_match(/>Complete</, response.body)
    end

    test 'show page uses db-backed rejection reason text in modal buttons' do
      income_body = 'DB income missing-name reason for modal test.'
      disability_certification_body = 'DB disability certification missing-signature reason for modal test.'

      RejectionReason.where(code: 'missing_name', proof_type: 'income', locale: 'en').destroy_all
      RejectionReason.where(code: 'missing_signature', proof_type: 'disability_certification', locale: 'en').destroy_all

      RejectionReason.create!(code: 'missing_name', proof_type: 'income', locale: 'en', body: income_body)
      RejectionReason.create!(code: 'missing_signature', proof_type: 'disability_certification', locale: 'en', body: disability_certification_body)

      get admin_application_path(@application)
      assert_response :success

      assert_select "dialog#proofRejectionModal button[data-reason-code='missing_name'][data-reason-text='#{income_body}']"
      assert_select "dialog#disabilityCertificationRejectionModal button[data-reason-code='missing_signature'][data-reason-text='#{disability_certification_body}']"
    end

    test 'show page fills the applicant address into reason previews, including for a dependent' do
      create(:rejection_reason, code: 'zz_preview_address', proof_type: 'residency', body: 'Send proof for %<address>s.')
      dependent_application = create(:application, :for_dependent,
                                     dependent_attrs: { first_name: 'Dependent', last_name: 'User', email: generate(:email),
                                                        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD',
                                                        zip_code: '21201' })

      get admin_application_path(dependent_application)

      assert_response :success
      assert_select "dialog#proofRejectionModal button[data-reason-code='zz_preview_address']" \
                    "[data-reason-text='Send proof for 123 Main St Baltimore, MD 21201.']"
    end

    test 'show page offers certification reasons in English and proof reasons in the applicant locale' do
      @application.user.update!(locale: 'es')
      create(:rejection_reason, code: 'zz_cert_locale', proof_type: 'disability_certification', locale: 'en', body: 'English certification text')
      create(:rejection_reason, code: 'zz_cert_locale', proof_type: 'disability_certification', locale: 'es', body: 'Texto de certificacion')
      create(:rejection_reason, code: 'zz_proof_locale', proof_type: 'income', locale: 'en', body: 'English income text')
      create(:rejection_reason, code: 'zz_proof_locale', proof_type: 'income', locale: 'es', body: 'Texto de ingresos')

      get admin_application_path(@application)

      assert_response :success
      assert_select "dialog#disabilityCertificationRejectionModal button[data-reason-code='zz_cert_locale'][data-reason-text='English certification text']"
      assert_select "dialog#proofRejectionModal button[data-reason-code='zz_proof_locale'][data-reason-text='Texto de ingresos']"
    end

    test 'show page certification upload form offers the stored certification reasons, including ones an admin added' do
      create(:rejection_reason, code: 'zz_admin_added', proof_type: 'disability_certification', body: 'Added by an admin')

      get admin_application_path(@application)

      assert_response :success
      assert_select "select#rejection_reason_code_select option[value='zz_admin_added'][data-reason-text='Added by an admin']"
      assert_select "select#rejection_reason_code_select option[value='missing_signature']"
    end

    test 'show page includes accessible rejection reason button attributes' do
      get admin_application_path(@application)
      assert_response :success

      assert_select "dialog#proofRejectionModal button[data-reason-code='address_mismatch'][aria-pressed='false']"
      assert_select "dialog#disabilityCertificationRejectionModal button[data-reason-code='missing_signature'][aria-pressed='false']"
      assert_select "dialog#proofRejectionModal [data-rejection-form-target='liveRegion'][aria-live='polite'][aria-atomic='true']"
      assert_select "dialog#disabilityCertificationRejectionModal [data-rejection-form-target='liveRegion'][aria-live='polite'][aria-atomic='true']"
      assert_select "dialog#proofRejectionModal [data-rejection-form-target='codeStatus']", text: /No predefined rejection reason selected\./
      assert_select "dialog#disabilityCertificationRejectionModal [data-rejection-form-target='codeStatus']", text: /No predefined rejection reason selected\./
    end

    test 'should reject proof and send rejection email' do
      ActionMailer::Base.perform_deliveries = true
      ActionMailer::Base.deliveries.clear

      app_needs_review = create(:application, :in_progress, income_proof_status: :not_reviewed)
      app_needs_review.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf')

      mock_proof_review = build(:proof_review,
                                application: app_needs_review,
                                proof_type: 'income',
                                status: 'rejected',
                                rejection_reason: 'Invalid document type',
                                notes: 'Please upload a PDF.')
      Applications::ProofReviewer.any_instance.stubs(:review).returns(mock_proof_review)

      # This stub suppresses mailer delivery. It does not assert a mailer call.
      mock_delivery = Struct.new(:deliver_later).new(true)
      ApplicationNotificationsMailer.any_instance.stubs(:proof_rejected).returns(mock_delivery)

      patch update_proof_status_admin_application_path(app_needs_review),
            params: {
              proof_type: 'income',
              status: 'rejected',
              rejection_reason: 'Invalid document type',
              notes: 'Please upload a PDF.'
            },
            as: :turbo_stream

      assert_response :success

      assert_equal 'text/vnd.turbo-stream.html', response.media_type

      assert_match 'Income proof rejected successfully', response.body

      # The service stub limits this test to the controller response, not persisted proof state.
    end

    test 'should send document signing request successfully' do
      mock_result = BaseService::Result.new(success: true, message: 'Document signing request sent successfully')
      mock_service = mock('service')
      mock_service.stubs(:call).returns(mock_result)
      DocumentSigning::SubmissionService.stubs(:new).with(
        application: @application,
        actor: @admin,
        service: 'docuseal'
      ).returns(mock_service)

      post send_document_signing_request_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
      assert_response :success
      assert_match(/Document signing request sent successfully/, flash[:notice])
    end

    test 'should handle document signing request failure' do
      mock_result = BaseService::Result.new(success: false, message: 'Certifying professional email is required')
      mock_service = mock('service')
      mock_service.stubs(:call).returns(mock_result)
      DocumentSigning::SubmissionService.stubs(:new).with(
        application: @application,
        actor: @admin,
        service: 'docuseal'
      ).returns(mock_service)

      post send_document_signing_request_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
      follow_redirect!(headers: { 'X-Test-User-Id' => @test_user_id.to_s })
      assert_response :success
      assert_match(/Certifying professional email is required/, flash[:alert])
    end

    test 'should pass correct parameters to document signing service' do
      mock_service = mock('service')
      mock_service.stubs(:call).returns(BaseService::Result.new(success: true, message: 'Success'))
      DocumentSigning::SubmissionService.expects(:new).with(
        application: @application,
        actor: @admin,
        service: 'docuseal'
      ).returns(mock_service).once

      post send_document_signing_request_admin_application_path(@application)

      assert_redirected_to admin_application_path(@application)
    end

    test 'update strips income params when income_proof_required is false' do
      @application.update_columns(income_proof_required: false)

      patch admin_application_path(@application), params: {
        application: {
          household_size: 5,
          annual_income: 99_999,
          status: @application.status
        }
      }

      @application.reload
      assert_not_equal 5, @application.household_size, 'household_size should not be updated when income is off'
      assert_not_equal 99_999.0, @application.annual_income, 'annual_income should not be updated when income is off'
    end

    test 'update allows income params when income_proof_required is true' do
      assert @application.income_proof_required?

      patch admin_application_path(@application), params: {
        application: {
          household_size: 5,
          annual_income: 55_000.0,
          status: @application.status
        }
      }

      @application.reload
      assert_equal 5, @application.household_size
      assert_equal 55_000.0, @application.annual_income
    end

    test 'update without real attribute changes does not log application_updated' do
      assert_no_difference -> { Event.where(action: 'application_updated', auditable: @application).count } do
        patch admin_application_path(@application), params: {
          application: {
            household_size: @application.household_size,
            annual_income: @application.annual_income,
            status: @application.status
          }
        }
      end

      assert_redirected_to admin_application_path(@application)
    end

    test 'the edit form cannot change status; status changes go through the workflow' do
      original_status = @application.status

      assert_no_difference -> { @application.status_changes.count } do
        patch admin_application_path(@application), params: { application: { status: 'approved', household_size: 4 } }
      end

      @application.reload
      assert_equal original_status, @application.status
      assert_equal 4, @application.household_size

      get edit_admin_application_path(@application)
      assert_select 'select[name="application[status]"]', count: 0
    end

    test 'batch_approve updates multiple applications and redirects' do
      app1 = create(:application, :in_progress)
      app2 = create(:application, :in_progress)

      Application.expects(:batch_update_status)
                 .with([app1.id.to_s, app2.id.to_s], :approved, actor: @admin)
                 .returns({ success: true, success_count: 2, errors: [] })

      post batch_approve_admin_applications_path, params: { ids: [app1.id, app2.id] }

      assert_redirected_to admin_applications_path
      assert_equal I18n.t('admin.applications.batch_approve.b_approved'), flash[:notice]
    end

    test 'batch_approve handles errors and returns unprocessable_content' do
      app1 = create(:application, :in_progress)

      Application.expects(:batch_update_status)
                 .with([app1.id.to_s], :approved, actor: @admin)
                 .returns({ success: false, success_count: 0, errors: ['Failed'] })

      post batch_approve_admin_applications_path, params: { ids: [app1.id] }

      assert_response :unprocessable_content
      assert_equal 'Unable to approve applications', response.parsed_body['error']
    end

    test 'batch_reject updates multiple applications and redirects' do
      app1 = create(:application, :in_progress)
      app2 = create(:application, :in_progress)

      Application.expects(:batch_update_status)
                 .with([app1.id.to_s, app2.id.to_s], :rejected, actor: @admin)
                 .returns({ success: true, success_count: 2, errors: [] })

      post batch_reject_admin_applications_path, params: { ids: [app1.id, app2.id] }

      assert_redirected_to admin_applications_path
      assert_equal I18n.t('admin.applications.batch_reject.b_rejected'), flash[:notice]
    end

    test 'batch_reject handles errors and returns unprocessable_content' do
      app1 = create(:application, :in_progress)

      Application.expects(:batch_update_status)
                 .with([app1.id.to_s], :rejected, actor: @admin)
                 .returns({ success: false, success_count: 0, errors: ['Failed'] })

      post batch_reject_admin_applications_path, params: { ids: [app1.id] }

      assert_response :unprocessable_content
      assert_equal 'Unable to reject applications', response.parsed_body['error']
    end

    private

    def create_pending_provider_info_application
      create(:application, :with_residency_proof, :with_id_proof).tap do |application|
        application.update!(
          residency_proof_status: :approved,
          id_proof_status: :approved,
          income_proof_required: false,
          status: :awaiting_proof,
          disability_certification_status: :requested,
          certifying_professional_name: nil,
          certifying_professional_phone: nil,
          certifying_professional_email: nil
        )
      end
    end

    def provider_info_link_ttl_hours
      Policy.get('secure_form_link_expiration_hours') || 48
    end

    def provider_info_recent_link_offset
      (provider_info_link_ttl_hours / 2.0).hours
    end

    def provider_info_summary_sent_text(time)
      I18n.t('admin.applications.secure_request_forms.summary.last_sent',
             time: I18n.l(time.to_date, format: :month_day))
    end

    def provider_info_summary_expires_text(time)
      I18n.t('admin.applications.secure_request_forms.summary.nearest_expiration',
             time: I18n.l(time.to_date, format: :month_day))
    end

    test 'queueing the certification form attaches the pregenerated PDF and leaves no named temporary file' do
      ensure_system_audit_actor!
      pregenerated = Rails.root.join('app/assets/pdfs/disability_certification_form.pdf')

      Dir.mktmpdir('dcf-queue') do |tmpdir|
        original_tmpdir = ENV.fetch('TMPDIR', nil)
        ENV['TMPDIR'] = tmpdir
        assert_difference 'PrintQueueItem.count', 1 do
          post queue_disability_certification_form_admin_application_path(@application),
               params: { operation_id: SecureRandom.uuid }, as: :turbo_stream
        end
        assert_response :success
        assert_empty Dir.children(tmpdir)
      ensure
        ENV['TMPDIR'] = original_tmpdir
      end

      item = PrintQueueItem.order(:id).last
      assert_equal @application, item.application
      assert_equal File.binread(pregenerated), item.pdf_letter.download
    end

    test 'refuses a certification with active content without attaching it' do
      script_pdf = Tempfile.new(['certification', '.pdf'])
      script_pdf.binmode
      script_pdf.write("%PDF-1.4\n/OpenAction << /S /JavaScript >>\n#{'x' * 2048}")
      script_pdf.close

      patch upload_disability_certification_admin_application_path(@application),
            params: { disability_certification: fixture_file_upload(script_pdf.path, 'application/pdf'),
                      disability_certification_status: 'approved' }

      assert_redirected_to admin_application_path(@application)
      assert_includes flash[:alert], I18n.t('documents.refused.suspicious_content')
      assert_not_predicate @application.reload.disability_certification, :attached?
    ensure
      script_pdf&.unlink
    end
  end
end
