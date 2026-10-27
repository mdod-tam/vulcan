# frozen_string_literal: true

require 'test_helper'

class DisabilityCertificationFormsControllerTest < ActionDispatch::IntegrationTest
  test 'downloads the blank disability certification form' do
    get disability_certification_form_path

    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert_includes response.headers['Content-Disposition'], 'attachment;'
    assert_equal '%PDF', response.body[0, 4]
  end

  test 'allows repeated downloads of the blank form' do
    get disability_certification_form_path
    assert_response :success

    get disability_certification_form_path
    assert_response :success
  end
end
