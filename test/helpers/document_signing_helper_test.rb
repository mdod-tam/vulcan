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
    assert_match(/badge badge-warning/, result)
  end

  test 'document_signing_status_badge returns badge for opened status' do
    @application.update!(document_signing_status: :opened)

    result = document_signing_status_badge(@application)
    assert_not_nil result
    assert_match(/Opened by Provider/, result)
    assert_match(/badge badge-info/, result)
  end

  test 'document_signing_status_badge returns badge for signed status' do
    @application.update!(document_signing_status: :signed)

    result = document_signing_status_badge(@application)
    assert_not_nil result
    assert_match(/Signed by Provider/, result)
    assert_match(/badge badge-success/, result)
  end

  test 'document_signing_status_badge returns badge for declined status' do
    @application.update!(document_signing_status: :declined)

    result = document_signing_status_badge(@application)
    assert_not_nil result
    assert_match(/Declined by Provider/, result)
    assert_match(/badge badge-danger/, result)
  end

  test 'document_signing_status_badge handles unknown status gracefully' do
    @application.update!(document_signing_status: :sent)

    # Force a status the helper has no specific case for.
    @application.define_singleton_method(:document_signing_status) do
      'unknown_status'
    end

    result = document_signing_status_badge(@application)
    assert_not_nil result
    assert_match(/Unknown status/, result)
    assert_match(/badge badge-neutral/, result) # default color
  end

  test 'document_signing_status_badge includes accessibility attributes' do
    @application.update!(document_signing_status: :signed)

    result = document_signing_status_badge(@application)
    assert_match(/Signed by Provider/, result)
    assert_match(/<span class="badge badge-success">/, result)
  end
end
