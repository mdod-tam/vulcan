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
      assert_equal [I18n.t('vendors.w9_resubmission.messages.file_blank', locale: @vendor.effective_locale)],
                   result.data.fetch(:errors).messages.fetch(:file)
    end

    test 'fails validation when file is not a PDF' do
      Tempfile.create(['w9-upload', '.txt']) do |file|
        file.write('not a pdf')
        file.rewind

        upload = Rack::Test::UploadedFile.new(file.path, 'text/plain', original_filename: 'w9.txt')
        result = SubmitW9Resubmission.new(
          vendor: @vendor,
          vendor_secure_request_form: @secure_request_form,
          file: upload
        ).call

        assert_not result.success?
        assert_equal I18n.t('vendors.w9_resubmission.messages.file_type_invalid', locale: @vendor.effective_locale),
                     result.data.fetch(:errors).messages.fetch(:file).first
      end
    end
  end
end
