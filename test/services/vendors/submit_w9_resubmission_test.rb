# frozen_string_literal: true

require 'test_helper'

module Vendors
  class SubmitW9ResubmissionTest < ActiveSupport::TestCase
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      @vendor = create(:vendor, :with_w9)
      @vendor.update!(w9_status: :rejected)
      @secure_request_form = create(:vendor_secure_request_form, vendor: @vendor)
    end

    test 'attaches corrected W9, marks form submitted, and moves vendor back to pending review' do
      file = fixture_file_upload(Rails.root.join('test/fixtures/files/sample_w9.pdf'), 'application/pdf')

      result = assert_difference("Event.where(action: 'w9_submitted_via_secure_form').count", 1) do
        SubmitW9Resubmission.new(
          vendor: @vendor,
          vendor_secure_request_form: @secure_request_form,
          file: file
        ).call
      end

      assert_predicate result, :success?
      assert_predicate @secure_request_form.reload, :submitted?
      assert_predicate @vendor.reload, :w9_status_pending_review?
      assert @vendor.w9_form.attached?

      event = Event.find_by!(auditable: @vendor, action: 'w9_submitted_via_secure_form')
      assert_equal @vendor, event.user
    end

    test 'audit failure rolls back the document archive status and consumed request together' do
      previous_w9 = @vendor.w9_form.blob
      create(:w9_review, :rejected, vendor: @vendor, reviewed_blob: previous_w9)
      upload = fixture_file_upload('sample_w9.pdf', 'application/pdf')
      AuditEventService.expects(:log).with(has_entries(action: 'w9_submitted_via_secure_form'))
                       .raises(ActiveRecord::RecordInvalid.new(Event.new))

      snapshot = lambda do
        @vendor.reload
        @secure_request_form.reload
        [@vendor.w9_form.blob.id, @vendor.w9_archive.blobs.ids.sort, @vendor.w9_status,
         @vendor.w9_rejections_count, @secure_request_form.status, @secure_request_form.submitted_at,
         Event.count, @vendor.w9_reviews.count]
      end

      assert_no_changes snapshot do
        result = SubmitW9Resubmission.new(vendor: @vendor, vendor_secure_request_form: @secure_request_form, file: upload).call
        assert_predicate result, :failure?
      end
      assert_predicate @vendor, :w9_status_rejected?
      assert_predicate @secure_request_form, :active_for_public_use?
      assert_equal previous_w9.id, @vendor.w9_form.blob.id
    end

    test 'fails when token does not belong to vendor' do
      other_vendor = create(:vendor, :with_w9)
      file = fixture_file_upload(Rails.root.join('test/fixtures/files/sample_w9.pdf'), 'application/pdf')

      result = SubmitW9Resubmission.new(
        vendor: other_vendor,
        vendor_secure_request_form: @secure_request_form,
        file: file
      ).call

      assert_not result.success?
      assert_equal I18n.t('vendors.w9_resubmission.messages.invalid_request', locale: other_vendor.effective_locale),
                   result.message
    end

    test 'fails validation when file is missing' do
      result = SubmitW9Resubmission.new(
        vendor: @vendor,
        vendor_secure_request_form: @secure_request_form,
        file: nil
      ).call

      assert_not result.success?
      assert_equal I18n.t('vendors.w9_resubmission.messages.validation_failed', locale: @vendor.effective_locale),
                   result.message
      assert_equal [I18n.t('documents.refused.missing', locale: @vendor.effective_locale)],
                   result.data.fetch(:errors).messages.fetch(:file)
    end

    test 'accepts JPEG W9 when Marcel detects image/jpeg' do
      Tempfile.create(['w9-upload', '.jpg'], binmode: true) do |jpeg|
        # The shared upload validator requires at least 1 KB.
        jpeg.write("\xFF\xD8\xFF\xE0".b + ("\x00".b * 2048))
        jpeg.rewind
        file = Rack::Test::UploadedFile.new(jpeg.path, 'image/jpeg', true, original_filename: 'w9.jpg')
        Marcel::MimeType.stubs(:for).returns('image/jpeg')

        result = SubmitW9Resubmission.new(
          vendor: @vendor,
          vendor_secure_request_form: @secure_request_form,
          file: file
        ).call

        assert_predicate result, :success?
        assert @vendor.w9_form.attached?
        assert_equal 'image/jpeg', @vendor.w9_form.content_type
      end
    end

    test 'fails validation when file type is not allowed' do
      Tempfile.create(['w9-upload', '.txt']) do |file|
        file.write('not a pdf ' * 200)
        file.rewind

        upload = Rack::Test::UploadedFile.new(file.path, 'text/plain', original_filename: 'w9.txt')
        result = SubmitW9Resubmission.new(
          vendor: @vendor,
          vendor_secure_request_form: @secure_request_form,
          file: upload
        ).call

        assert_not result.success?
        assert_equal I18n.t('documents.refused.invalid_type', locale: @vendor.effective_locale),
                     result.data.fetch(:errors).messages.fetch(:file).first
      end
    end

    test 'rejects a W9 PDF with active content like proof and certification uploads' do
      Tempfile.create(['w9-upload', '.pdf'], binmode: true) do |pdf|
        pdf.write("%PDF-1.4\n1 0 obj << /OpenAction << /S /JavaScript /JS (app.alert(1)) >> >>\n".b + (' ' * 2048))
        pdf.rewind
        upload = Rack::Test::UploadedFile.new(pdf.path, 'application/pdf', true, original_filename: 'w9.pdf')
        original_blob_id = @vendor.w9_form.blob.id

        result = SubmitW9Resubmission.new(
          vendor: @vendor,
          vendor_secure_request_form: @secure_request_form,
          file: upload
        ).call

        assert_not result.success?
        assert_equal I18n.t('documents.refused.suspicious_content', locale: @vendor.effective_locale),
                     result.data.fetch(:errors).messages.fetch(:file).first
        assert_equal original_blob_id, @vendor.reload.w9_form.blob.id
      end
    end
    test 'a W-9 of exactly 10 MB is refused and the request stays active' do
      previous_w9 = @vendor.w9_form.blob
      tempfile = Tempfile.new(['w9', '.pdf'])
      tempfile.binmode
      tempfile.write("%PDF-1.4\n#{'x' * (ProofUploadFormats.max_bytes(:w9) - 9)}")
      tempfile.rewind
      file = ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: 'w9.pdf', type: 'application/pdf')

      result = SubmitW9Resubmission.new(vendor: @vendor, vendor_secure_request_form: @secure_request_form, file: file).call

      assert_not result.success?
      assert_equal :too_large, result.data[:errors].details[:file].first[:error]
      assert_not_predicate @secure_request_form.reload, :submitted?
      assert_equal previous_w9, @vendor.reload.w9_form.blob
    ensure
      tempfile&.close!
    end
  end
end
