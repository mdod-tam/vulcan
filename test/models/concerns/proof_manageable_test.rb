# frozen_string_literal: true

require 'test_helper'

class ProofManageableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionDispatch::TestProcess::FixtureFile

  setup do
    @application = create(:application, :in_progress_with_pending_proofs)
    @valid_pdf = fixture_file_upload('test/fixtures/files/residency_proof.pdf', 'application/pdf')
  end

  test 'allows valid PDF uploads' do
    @application.income_proof.attach(@valid_pdf)
    assert @application.valid?
    assert @application.income_proof.attached?
  end

  test 'portal replacement requires a rejected proof and an open application even at the warning threshold' do
    @application.assign_attributes(total_rejections: ProofReview::MAX_REJECTIONS, income_proof_status: :rejected)
    assert @application.proof_resubmittable_via_portal?('income')

    %i[approved archived].each do |status|
      @application.status = status
      assert_not @application.proof_resubmittable_via_portal?('income')
    end

    @application.assign_attributes(status: :in_progress, income_proof_status: :not_reviewed)
    assert_not @application.proof_resubmittable_via_portal?('income')
  end

  test 'validates both income and residency proofs independently' do
    @application.income_proof.attach(@valid_pdf)
    @application.residency_proof.attach(fixture_file_upload('test/fixtures/files/invalid.exe', 'application/x-msdownload'))

    assert_not @application.valid?
    assert_empty @application.errors[:income_proof]
    assert_includes @application.errors[:residency_proof],
                    "must be a PDF or an image file (#{ProofUploadFormats::HUMAN_LABEL})"
  end
end
