# frozen_string_literal: true

require 'test_helper'

class ActiveStorageProofPreviewTest < ActionDispatch::IntegrationTest
  include ActionDispatch::TestProcess::FixtureFile

  test 'requires applicant sign-in before serving a jpg proof inline' do
    application = create(:application, :in_progress)
    application.income_proof.attach(
      fixture_file_upload(Rails.root.join('test/fixtures/files/sample.jpg'), 'image/jpeg')
    )
    mark_document_clean!(application.income_proof.blob, user: application.user)

    preview_path = rails_storage_proxy_path(application.income_proof.blob, disposition: 'inline')
    get preview_path
    assert_redirected_to sign_in_path
    assert_includes response.headers.fetch('Cache-Control'), 'no-store'

    sign_in_for_integration_test(application.user)
    get preview_path

    assert_response :success
    assert_match(/\Ainline\b/, response.headers.fetch('Content-Disposition'))
  end
end
