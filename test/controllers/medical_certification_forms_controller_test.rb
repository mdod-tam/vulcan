# frozen_string_literal: true

require 'test_helper'

class MedicalCertificationFormsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @constituent = create(:constituent)
    @application = create(:application,
                          user: @constituent,
                          medical_provider_name: 'Dr. Smith',
                          medical_provider_email: 'provider@example.com',
                          medical_certification_status: :requested)
  end

  test 'downloads form for valid signed id' do
    signed_id = MedicalCertificationFormLink.signed_id_for(@application)

    get medical_certification_form_path(signed_id: signed_id)

    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert_includes response.headers['Content-Disposition'], 'attachment;'
    assert_equal '%PDF', response.body[0, 4]
  end

  test 'returns not found for invalid signed id' do
    get medical_certification_form_path(signed_id: 'invalid-token')

    assert_response :not_found
  end

  test 'returns not found for expired signed id' do
    signed_id = @application.signed_id(
      purpose: MedicalCertificationFormLink::PURPOSE,
      expires_in: 1.second
    )

    travel 2.seconds do
      get medical_certification_form_path(signed_id: signed_id)
    end

    assert_response :not_found
  end

  test 'revokes a link after first successful download' do
    signed_id = MedicalCertificationFormLink.signed_id_for(@application)

    get medical_certification_form_path(signed_id: signed_id)
    assert_response :success

    get medical_certification_form_path(signed_id: signed_id)
    assert_response :not_found
  end

  test 'returns not found when certification is approved' do
    @application.update!(medical_certification_status: :approved)
    signed_id = MedicalCertificationFormLink.signed_id_for(@application)

    get medical_certification_form_path(signed_id: signed_id)

    assert_response :not_found
  end
end
