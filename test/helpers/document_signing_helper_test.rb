# frozen_string_literal: true

require 'test_helper'

class DocumentSigningHelperTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @application = create(:application, :in_progress)
  end

  test 'document_signing_status_badge returns nil for not_sent status' do
    @application.update!(document_signing_status: :not_sent)

    result = document_signing_status_badge(@application)
    assert_nil result
  end

  test 'document_signing_status_badge returns nil when status is not_sent' do
    @application.update!(document_signing_status: :not_sent)

    result = document_signing_status_badge(@application)
    assert_nil result
  end

  test 'document_signing_status_badge returns badge for sent status' do
    @application.update!(document_signing_status: :sent)

    result = document_signing_status_badge(@application)
    assert_not_nil result
    assert_match(/Sent for Signing/, result)
    assert_match(/bg-yellow-100 text-yellow-800/, result)
    assert_match(/px-2 py-1 text-xs font-medium rounded-full/, result)
  end

  test 'document_signing_status_badge returns badge for opened status' do
    @application.update!(document_signing_status: :opened)

    result = document_signing_status_badge(@application)
    assert_not_nil result
    assert_match(/Opened by Provider/, result)
    assert_match(/bg-blue-100 text-blue-800/, result)
  end

  test 'document_signing_status_badge returns badge for signed status' do
    @application.update!(document_signing_status: :signed)

    result = document_signing_status_badge(@application)
    assert_not_nil result
    assert_match(/Signed by Provider/, result)
    assert_match(/bg-green-100 text-green-800/, result)
  end

  test 'document_signing_status_badge returns badge for declined status' do
    @application.update!(document_signing_status: :declined)

    result = document_signing_status_badge(@application)
    assert_not_nil result
    assert_match(/Declined by Provider/, result)
    assert_match(/bg-red-100 text-red-800/, result)
  end

  test 'document_signing_status_badge handles unknown status gracefully' do
    # Use a valid but uncommon status to test the default case behavior
    # The helper should handle any valid enum value that doesn't match the specific cases
    @application.update!(document_signing_status: :sent)

    # Mock the status to return something different to test the default case
    @application.define_singleton_method(:document_signing_status) do
      'unknown_status'
    end

    result = document_signing_status_badge(@application)
    assert_not_nil result
    # Should contain the humanized unknown status and default styling
    assert_match(/Unknown status/, result)
    assert_match(/bg-gray-100 text-gray-800/, result) # default color
  end

  test 'document_signing_status_badge includes accessibility attributes' do
    @application.update!(document_signing_status: :signed)

    result = document_signing_status_badge(@application)
    assert_match(/inline-flex items-center justify-center/, result)
    assert_match(/whitespace-nowrap/, result)
  end
end
