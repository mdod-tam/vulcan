# frozen_string_literal: true

require 'test_helper'

class ActiveStorageConfigTest < ActiveSupport::TestCase
  test 'the effective inline policy matches the accepted proof formats after boot' do
    assert_equal ProofUploadFormats::ALLOWED_CONTENT_TYPES, ActiveStorage.content_types_allowed_inline
    assert_empty ActiveStorage.content_types_allowed_inline & %w[text/html image/svg+xml]
  end
end
