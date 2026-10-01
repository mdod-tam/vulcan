# frozen_string_literal: true

require 'test_helper'

class ProofUploadFormatsTest < ActiveSupport::TestCase
  test 'allowed content types include pdf jpeg png and heic variants' do
    assert_includes ProofUploadFormats::ALLOWED_CONTENT_TYPES, 'application/pdf'
    assert_includes ProofUploadFormats::ALLOWED_CONTENT_TYPES, 'image/jpeg'
    assert_includes ProofUploadFormats::ALLOWED_CONTENT_TYPES, 'image/png'
    assert_includes ProofUploadFormats::ALLOWED_CONTENT_TYPES, 'image/heic'
    assert_includes ProofUploadFormats::ALLOWED_CONTENT_TYPES, 'image/heif'
    assert_includes ProofUploadFormats::ALLOWED_CONTENT_TYPES, 'image/tiff'
  end

  test 'accept attribute includes extensions and mime types for mobile uploads' do
    assert_includes ProofUploadFormats::ACCEPT_ATTRIBUTE, '.heic'
    assert_includes ProofUploadFormats::ACCEPT_ATTRIBUTE, 'image/heic'
    assert_includes ProofUploadFormats::ACCEPT_ATTRIBUTE, '.tif'
    assert_includes ProofUploadFormats::ACCEPT_ATTRIBUTE, '.tiff'
    assert_includes ProofUploadFormats::ACCEPT_ATTRIBUTE, 'image/tiff'
  end

  test 'human label mentions HEIF and TIFF' do
    assert_includes ProofUploadFormats::HUMAN_LABEL, 'HEIF'
    assert_includes ProofUploadFormats::HUMAN_LABEL, 'TIFF'
  end
end
