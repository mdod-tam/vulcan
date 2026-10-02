# frozen_string_literal: true

require 'test_helper'

class ProofAttachmentValidatorTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess::FixtureFile

  test 'accepts HEIC when Marcel detects image/heic' do
    upload = fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'image/heic',
                                 original_filename: 'proof.heic')
    Marcel::MimeType.stubs(:for).returns('image/heic')

    assert ProofAttachmentValidator.check_content!(upload)
  end

  test 'rejects disallowed types when Marcel detects text/plain' do
    upload = fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'text/plain',
                                 original_filename: 'proof.txt')
    Marcel::MimeType.stubs(:for).returns('text/plain')

    error = assert_raises(ProofAttachmentValidator::ValidationError) do
      ProofAttachmentValidator.check_content!(upload)
    end

    assert_equal :invalid_type, error.error_type
  end

  test 'rejects a PDF with active content' do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.4\n/OpenAction << /JavaScript (x) >>"),
                                                  filename: 'form.pdf', content_type: 'application/pdf')

    error = assert_raises(ProofAttachmentValidator::ValidationError) do
      ProofAttachmentValidator.check_content!(blob)
    end

    assert_equal :suspicious_content, error.error_type
  end
end
