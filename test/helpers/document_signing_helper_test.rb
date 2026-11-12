# frozen_string_literal: true

require 'test_helper'

class DocumentSigningHelperTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    @application = build(:application, :in_progress)
  end

  test 'document_signing_status_badge returns nil for not_sent status' do
    @application.assign_attributes(document_signing_status: :not_sent)

    result = document_signing_status_badge(@application)
    assert_nil result
  end

  test 'document signing badges keep each status label, variant and span markup' do
    {
      sent: ['Sent for Signing', 'warning'],
      opened: ['Opened by Provider', 'info'],
      signed: ['Signed by Provider', 'success'],
      declined: ['Declined by Provider', 'danger']
    }.each do |status, (label, variant)|
      @application.document_signing_status = status
      result = document_signing_status_badge(@application)

      assert_match(/#{Regexp.escape(label)}/, result, status.to_s)
      assert_match(/<span class="badge badge-#{variant}">/, result, status.to_s)
    end
  end

  test 'document_signing_status_badge handles unknown status gracefully' do
    @application.assign_attributes(document_signing_status: :sent)

    # Force a status the helper has no specific case for.
    @application.define_singleton_method(:document_signing_status) do
      'unknown_status'
    end

    result = document_signing_status_badge(@application)
    assert_match(/Unknown status/, result)
    assert_match(/badge badge-neutral/, result) # default color
  end
end
