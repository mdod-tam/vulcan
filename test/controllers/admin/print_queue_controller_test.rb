# frozen_string_literal: true

require 'test_helper'

module Admin
  class PrintQueueControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      ensure_system_audit_actor!
      @recipient = create(:constituent)
      @application = create(:application, user: @recipient)
      @letters = 2.times.map do
        Letters::Delivery.queue!(recipient: @recipient, application: @application, letter_type: :medical_certification_form,
                                 context: EmailDelivery::Policy.capture(mail_action: 'Letters#medical_certification_form')) do
          StringIO.new('%PDF test letter')
        end
      end
      sign_in_for_integration_test(@admin)
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
    end

    test 'a refused batch preserves selection and releases nothing' do
      EmailDelivery::ControlWriter.set(name: EmailDelivery::ALL_CONTROL, enabled: false, actor: @admin, operation_id: SecureRandom.uuid)
      post download_batch_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }
      assert_response :unprocessable_content
      assert_includes response.body, 'Nothing was released'
      assert(@letters.all? { |item| item.reload.released_at.nil? && item.canceled? })
    end

    test 'physical print confirmation cannot skip release' do
      post mark_batch_as_printed_admin_print_queue_index_path, params: { letter_ids: @letters.map(&:id) }
      assert_response :unprocessable_content
      assert(@letters.all? { |item| item.reload.pending? })
    end

    test 'signed storage URLs cannot bypass release but ordinary PDFs remain downloadable' do
      blob = @letters.first.pdf_letter.blob
      get rails_blob_path(blob, only_path: true)
      assert_response :not_found
      get rails_storage_proxy_path(blob, only_path: true)
      assert_response :not_found
      reference = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('%PDF blank'), filename: 'blank.pdf', content_type: 'application/pdf')
      get rails_blob_path(reference, only_path: true)
      assert_response :success
      assert_equal '%PDF blank', response.body
    end
  end
end
