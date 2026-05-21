# frozen_string_literal: true

require 'test_helper'

class ActiveStorageProofPreviewTest < ActionDispatch::IntegrationTest
  include ActionDispatch::TestProcess::FixtureFile

  test 'serves jpg proof blob proxy inline when requested' do
    application = create(:application, :in_progress)
    application.income_proof.attach(
      fixture_file_upload(Rails.root.join('test/fixtures/files/sample.jpg'), 'image/jpeg')
    )

    get rails_storage_proxy_path(application.income_proof.blob, disposition: 'inline')

    assert_response :success
    assert_match(/\Ainline\b/, response.headers.fetch('Content-Disposition'))
  end
end
