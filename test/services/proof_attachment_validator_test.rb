# frozen_string_literal: true

require 'test_helper'

class ProofAttachmentValidatorTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess::FixtureFile

  test 'accepts HEIC when Marcel detects image/heic' do
    upload = fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'image/heic',
                                 original_filename: 'proof.heic')
    Marcel::MimeType.stubs(:for).returns('image/heic')

    assert ProofAttachmentValidator.validate!(upload)
  end

  test 'rejects disallowed types when Marcel detects text/plain' do
    upload = fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'text/plain',
                                 original_filename: 'proof.txt')
    Marcel::MimeType.stubs(:for).returns('text/plain')

    error = assert_raises(ProofAttachmentValidator::ValidationError) do
      ProofAttachmentValidator.validate!(upload)
    end

    assert_equal :invalid_type, error.error_type
  end
end
