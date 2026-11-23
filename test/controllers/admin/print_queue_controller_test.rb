# frozen_string_literal: true

require 'test_helper'

module Admin
  class PrintQueueControllerTest < ActionDispatch::IntegrationTest
    include PdfTextHelper

    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @recipient = create(:constituent)
      @application = create(:application, user: @recipient)
      @letters = 2.times.map do
        Letters::Delivery.queue!(recipient: @recipient, application: @application, letter_type: :disability_certification_form,
                                 context: EmailDelivery::Policy.capture(mail_action: 'Letters#disability_certification_form')) do
          StringIO.new('%PDF test letter')
        end
      end
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
    end

    test 'metadata and legacy GET routes never release a PDF' do
      get admin_print_queue_index_path
      assert_response :success
      assert_select 'h1', text: 'Print Queue'
      assert_select 'input[name="letter_ids[]"]', count: 2
      get admin_print_queue_path(@letters.first)
      assert_response :success
      assert_select 'iframe', count: 0
      get admin_print_queue_path(@letters.first, format: :pdf)
      assert_response :see_other
      get download_batch_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }
      assert_response :see_other
      head download_batch_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }
      assert_response :see_other
      head batch_admin_print_queue_index_path(ids: @letters.map(&:id).join(','))
      assert_response :success
      assert_empty response.body
      assert(@letters.all? { |item| item.reload.released_at.nil? })
    end

    test 'POST release returns a private PDF and marking printed is separate' do
      post release_admin_print_queue_path(@letters.first)
      assert_response :success
      assert_equal 'application/pdf', response.media_type
      assert_includes response.headers['Cache-Control'], 'no-store'
      assert @letters.first.reload.released_at
      assert @letters.first.pending?
      post mark_as_printed_admin_print_queue_path(@letters.first)
      assert_redirected_to admin_print_queue_index_path
      assert @letters.first.reload.printed?
    end

    test 'POST batch returns a complete zip with distinct filenames' do
      post download_batch_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }
      assert_response :success
      assert_equal 'application/zip', response.media_type
      Zip::File.open_buffer(response.body) { |zip| assert_equal @letters.map(&:pdf_filename).sort, zip.entries.map(&:name).sort }
      assert(@letters.all? { |item| item.reload.released_at })
      get response.headers.fetch('Content-Location')
      assert_select 'h1', text: 'Print batch'
      assert_equal @letters.map { |letter| letter.id.to_s }.sort, css_select('input[name="letter_ids[]"][checked]').pluck('value').sort

      selected, skipped = @letters
      get batch_admin_print_queue_index_path(ids: @letters.map(&:id).join(','), skipped: skipped.id)
      assert_select "#letter-#{selected.id}[checked]"
      assert_select "#letter-#{skipped.id}[checked]", count: 0
    end

    test 'a refused batch preserves selection and releases nothing' do
      EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: false, actor: @admin, operation_id: SecureRandom.uuid)
      post download_batch_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }
      assert_response :unprocessable_content
      assert_includes response.body, 'Nothing was released'
      assert(@letters.all? { |item| item.reload.released_at.nil? && item.canceled? })
    end

    test 'a batch with a missing PDF keeps only the available letter selected' do
      missing, available = @letters
      missing.pdf_letter.detach

      post download_batch_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }

      assert_response :unprocessable_content
      assert_includes response.body, "Letter ##{missing.id}: The PDF is missing."
      assert_select "#letter-#{missing.id}[checked]", count: 0
      assert_select "#letter-#{available.id}[checked]"
      assert_nil available.reload.released_at
    end

    test 'a missing stored file identifies its letter and leaves good rows selected' do
      missing, available = @letters
      missing.pdf_letter.blob.service.delete(missing.pdf_letter.blob.key)

      post download_batch_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }

      assert_response :unprocessable_content
      assert_includes response.body, "Letter ##{missing.id}: The PDF is missing."
      assert_select "#letter-#{missing.id}[checked]", count: 0
      assert_select "#letter-#{available.id}[checked]"
      assert(@letters.none? { |item| item.reload.released_at? })
    end

    test 'one mail action records printing and outgoing mail without rewriting history on retry' do
      letter = issue_paper_proof(paper_application).print_queue_items.sole
      post release_admin_print_queue_path(letter)
      params = { letter_ids: [letter.id], ids: letter.id.to_s }

      post mark_in_outgoing_mail_admin_print_queue_index_path, params: params

      assert_redirected_to batch_admin_print_queue_index_path(ids: letter.id)
      assert_predicate letter.reload, :printed?
      assert_equal @admin, letter.admin
      assert_equal @admin, letter.mail_handoff_by
      assert_equal 1, Event.where(action: 'letter_printed', auditable: letter).count
      assert_equal 1, Event.where(action: 'letter_in_outgoing_mail', auditable: letter).count
      before = [letter.printed_at, letter.mail_handoff_at]

      travel 1.hour do
        post mark_in_outgoing_mail_admin_print_queue_index_path, params: params
      end

      assert_equal before, [letter.reload.printed_at, letter.mail_handoff_at]
      assert_not PrintQueueItem.outstanding.exists?(letter.id)
    end

    test 'an address change blocks mail handoff but preserves the record of printing' do
      letter = issue_paper_proof(paper_application).print_queue_items.sole
      other_letter = @letters.first
      ids = [letter.id, other_letter.id]
      post download_batch_admin_print_queue_index_path, params: { letter_ids: ids }
      letter.constituent.update!(physical_address_1: '76 New Street')

      get batch_admin_print_queue_index_path(ids: letter.id)
      assert_select "#mail_warning_print_queue_item_#{letter.id}", text: /Do not mail/
      post mark_in_outgoing_mail_admin_print_queue_index_path, params: { letter_ids: [letter.id], ids: ids.join(',') }
      assert_response :unprocessable_content
      assert_select "#letter-#{letter.id}[checked]"
      assert_select "#letter-#{other_letter.id}[checked]", count: 0
      assert_nil letter.reload.mail_handoff_at
      assert_nil letter.printed_at

      post mark_as_printed_admin_print_queue_path(letter)
      printed_at = letter.reload.printed_at
      assert printed_at
      assert PrintQueueItem.awaiting_mail_handoff.exists?(letter.id)

      post discard_printed_copy_admin_print_queue_path(letter)
      assert_equal printed_at, letter.reload.printed_at
      assert letter.mail_discarded_at?
      assert_not PrintQueueItem.outstanding.exists?(letter.id)
    end

    test 'failed or overdue preparation is visible until the follow-up is resolved' do
      failed, overdue = %i[error queued].map do |status|
        create(:notification, action: Notification::PAPER_REJECTION_LETTER_ACTION, recipient: @admin, notifiable: @recipient,
                              delivery_status: status, created_at: 2.hours.ago)
      end
      current = create(:notification, action: Notification::PAPER_REJECTION_LETTER_ACTION, recipient: @admin, notifiable: @recipient, delivery_status: :queued)

      get admin_print_queue_index_path
      assert_select 'section[aria-labelledby="print-attention-heading"]' do
        assert_select 'a', text: "Review notice ##{failed.id}"
        assert_select 'a', text: "Review notice ##{overdue.id}"
        assert_select 'a', text: "Review notice ##{current.id}", count: 0
      end

      post dismiss_preparation_failure_admin_print_queue_index_path, params: { notification_id: failed.id }
      follow_redirect!
      assert_select 'a', text: "Review notice ##{failed.id}", count: 0
      assert_select 'a', text: "Review notice ##{overdue.id}"
    end

    test 'physical print confirmation cannot skip release' do
      post mark_batch_as_printed_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }
      assert_response :unprocessable_content
      assert(@letters.all? { |item| item.reload.pending? })
    end

    test 'canceling a released letter keeps the release and closes outstanding work' do
      item = @letters.first
      post release_admin_print_queue_path(item)
      released_at = item.reload.released_at
      assert released_at

      post cancel_admin_print_queue_path(item)
      assert_redirected_to admin_print_queue_path(item)
      assert_predicate item.reload, :canceled?
      assert_equal released_at, item.released_at
      assert_nil item.printed_at
      assert_not PrintQueueItem.pending.exists?(item.id)
      assert_equal :canceled, item.display_delivery_state

      post release_admin_print_queue_path(item), as: :turbo_stream
      assert_response :unprocessable_content
      assert_select 'turbo-stream[target="print-letter-content"]'
      post mark_as_printed_admin_print_queue_path(item)
      assert_response :unprocessable_content
      assert_nil item.reload.printed_at
    end

    test 'expired proof letter stays printable, replacement retires the old release, and mailed proof can be recorded' do
      application = paper_application
      result = Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :id).call
      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).sole
      item = form.print_queue_items.sole
      pdf_text = extracted_pdf_text(item.pdf_letter.download)
      assert_includes pdf_text, 'mail a copy of your document'
      assert_no_match(/[?&]token=/, pdf_text)

      travel_to form.sent_at + 72.hours do
        sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
        assert_not form.reload.active_for_public_use?
        post release_admin_print_queue_path(item)
        assert_response :success
        released_at = item.reload.released_at
        assert released_at

        assert_difference('PrintQueueItem.count', 1) { post replace_request_admin_print_queue_path(item) }
        assert_predicate form.reload, :revoked?
        assert_predicate item.reload, :canceled?
        assert_equal released_at, item.released_at
        assert_no_difference('PrintQueueItem.count') { post replace_request_admin_print_queue_path(item) }
      end

      travel_to form.sent_at + 7.days do
        sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
        replacement = PrintQueueItem.where(application: application).pending.sole
        post release_admin_print_queue_path(replacement)
        assert_response :success
        post mark_as_printed_admin_print_queue_path(replacement)

        upload = scanned_upload(fixture_file_upload('id_proof.pdf', 'application/pdf'), user: @admin, slot: 'id_proof')
        post admin_application_mailed_proof_path(application), params: { proof_type: 'id', id_proof_signed_id: upload.signed_id }
        assert_redirected_to admin_application_path(application)
        assert_equal upload.id, application.reload.id_proof.blob.id
        assert_predicate application, :id_proof_status_not_reviewed?
        assert_not replacement.secure_request_form.postal_delivery_eligible?
        assert_predicate replacement.reload, :printed?
      end
    end

    test 'provider details received by phone resolve a paper request after the token expires' do
      application = paper_application
      result = Applications::RequestProviderInfo.new(application: application, actor: @admin).call
      assert_predicate result, :success?
      form = result.data.fetch(:secure_request_forms).sole
      item = form.print_queue_items.sole
      pdf_text = extracted_pdf_text(item.pdf_letter.download)
      assert_includes pdf_text, 'Please contact our team by phone'
      assert_no_match(/[?&]token=/, pdf_text)

      travel_to form.sent_at + 7.days do
        sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
        assert_not form.reload.active_for_public_use?
        post release_admin_print_queue_path(item)
        assert_response :success
        post mark_as_printed_admin_print_queue_path(item)
        patch admin_application_path(application), params: { application: { certifying_professional_name: 'Provider Name' } }
        assert_redirected_to admin_application_path(application)
        assert_not application.reload.missing_required_provider_info?
        assert_not form.reload.postal_delivery_eligible?
        assert_predicate form, :revoked?
        assert_predicate item.reload, :printed?
      end
    end

    test 'a mailed proof closes its request and leaves the downloaded copy to resolve' do
      application = paper_application
      form = issue_paper_proof(application)
      letter = form.print_queue_items.sole
      post release_admin_print_queue_path(letter)
      assert_response :success

      upload = scanned_upload(fixture_file_upload('id_proof.pdf', 'application/pdf'), user: @admin, slot: 'id_proof')
      post admin_application_mailed_proof_path(application), params: { proof_type: 'id', id_proof_signed_id: upload.signed_id }
      assert_redirected_to admin_application_path(application)
      assert_predicate form.reload, :revoked?
      assert_predicate letter.reload, :pending?
      get admin_print_queue_path(letter)
      assert_select 'dd', text: 'Resolve downloaded copy'
      assert_select 'button', text: 'Discard unused copy'
      post cancel_admin_print_queue_path(letter)
      assert_predicate letter.reload, :canceled?
      assert letter.released_at
    end

    test 'release requires a current relationship for the selected guardian' do
      application = paper_application
      manager = create(:constituent)
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: manager, dependent_user: application.user)
      relationship = create(:guardian_relationship, guardian_user: guardian, dependent_user: application.user)
      application.update!(managing_guardian: manager)
      result = Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :id,
                                                          recipient_ids: [guardian.id], channel_overrides: { guardian.id => :letter }).call
      assert_predicate result, :success?
      letter = result.data.fetch(:secure_request_forms).sole.print_queue_items.sole

      delete admin_guardian_relationship_path(relationship)
      assert_not GuardianRelationship.exists?(relationship.id)
      post release_admin_print_queue_path(letter)

      assert_response :unprocessable_content
      assert_includes response.body, 'Recipient no longer eligible.'
      assert_nil letter.reload.released_at
    end

    test 'revoking an open paper request retires its unreleased letter' do
      form = issue_paper_proof(paper_application)
      post admin_application_secure_request_form_revocation_path(form.application, form)

      assert_predicate form.reload, :revoked?
      assert_predicate form.print_queue_items.sole, :canceled?
    end

    test 'rejecting returned proof can issue a new letter after the old request closes' do
      application = paper_application
      form = issue_paper_proof(application)
      upload = scanned_upload(fixture_file_upload('id_proof.pdf', 'application/pdf'), user: @admin, slot: 'id_proof')
      post admin_application_mailed_proof_path(application), params: { proof_type: 'id', id_proof_signed_id: upload.signed_id }

      assert_predicate form.reload, :revoked?
      assert_predicate form.print_queue_items.sole, :canceled?
      assert_difference('PrintQueueItem.count', 1) do
        patch update_proof_status_admin_application_path(application), params: {
          proof_type: 'id', status: 'rejected', rejection_reason: 'Unreadable copy',
          reviewed_blob_id: upload.id, decision_key: SecureRandom.uuid
        }
      end
      assert_predicate application.reload, :id_proof_status_rejected?
      assert_predicate application.secure_request_forms.id_proof.open_requests.sole.print_queue_items.sole.delivery_decision, :allowed?
    end

    test 'a replacement preparation failure leaves the original printable' do
      form = issue_paper_proof(paper_application)
      letter = form.print_queue_items.sole

      travel_to form.sent_at + 72.hours do
        sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
        Letters::TextTemplateToPdfService.any_instance.stubs(:generate_pdf).raises(IOError, 'synthetic renderer failure')

        assert_no_difference(['SecureRequestForm.count', 'PrintQueueItem.count']) do
          post replace_request_admin_print_queue_path(letter)
        end

        assert_match 'The previous letter is still available.', flash[:alert]
        assert_predicate form.reload, :postal_request_open?
        assert_predicate letter.reload.delivery_decision, :allowed?
      end
    end

    test 'a replacement handoff failure rolls back retirement and admission together' do
      form = issue_paper_proof(paper_application)
      letter = form.print_queue_items.sole

      travel_to form.sent_at + 72.hours do
        sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
        Notification.any_instance.stubs(:record_delivery_handoff!).raises(IOError, 'synthetic handoff failure')

        assert_no_difference(['SecureRequestForm.count', 'Notification.count', 'PrintQueueItem.count', 'ActiveStorage::Blob.count']) do
          post replace_request_admin_print_queue_path(letter)
        end

        assert_match 'The previous letter is still available.', flash[:alert]
        assert_predicate form.reload, :postal_request_open?
        assert_predicate letter.reload.delivery_decision, :allowed?
      end
    end

    test 'signed storage URLs cannot bypass release and unattached PDFs are not public' do
      blob = @letters.first.pdf_letter.blob
      get rails_blob_path(blob, only_path: true)
      assert_response :not_found
      get rails_storage_proxy_path(blob, only_path: true)
      assert_response :not_found
      @application.income_proof.attach(blob)
      get rails_blob_path(blob, only_path: true)
      assert_response :not_found
      assert_nil @letters.first.reload.released_at
      reference = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('%PDF blank'), filename: 'blank.pdf', content_type: 'application/pdf')
      get rails_blob_path(reference, only_path: true)
      assert_response :not_found
    end

    private

    def issue_paper_proof(application)
      result = Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :id).call
      assert_predicate result, :success?
      result.data.fetch(:secure_request_forms).sole
    end

    def paper_application
      recipient = Current.set(paper_context: true) do
        create(:constituent, email: nil, phone: nil, communication_preference: :letter)
      end
      create(:application, user: recipient, status: :awaiting_proof, certifying_professional_name: nil)
    end
  end
end
