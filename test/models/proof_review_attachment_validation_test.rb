# frozen_string_literal: true

require 'test_helper'

# The attachment rule is the same in every environment: a review needs the attachment its document type names, except
# a rejected certification or a rejected paper proof, which can have none.
class ProofReviewAttachmentValidationTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @application = create(:application, :in_progress, skip_proofs: true)
    attach(@application.income_proof, 'income.pdf')
    attach(@application.residency_proof, 'residency.pdf')
  end

  test 'an approved review passes when its document type has an attachment' do
    %i[income residency].each do |proof_type|
      review = build_review(proof_type)

      assert review.valid?, "Expected an approved #{proof_type} review to be valid: #{review.errors.full_messages}"
    end
  end

  test 'an approved id review needs the id proof attachment' do
    review = build_review(:id)

    assert_not review.valid?
    assert_includes review.errors[:base], 'No id proof found for review'

    attach(@application.id_proof, 'id.pdf')

    assert build_review(:id).valid?
  end

  test 'an approved disability certification review needs the certification attachment' do
    review = build_review(:disability_certification)

    assert_not review.valid?
    assert_includes review.errors[:base], 'No disability_certification proof found for review'

    attach(@application.disability_certification, 'certification.pdf')

    assert build_review(:disability_certification).valid?
  end

  test 'a rejected disability certification review needs no attachment' do
    review = build_review(:disability_certification, status: :rejected)

    assert review.valid?, "Expected a rejected certification review to be valid: #{review.errors.full_messages}"
  end

  test 'a rejected proof needs its attachment unless it came from a paper submission' do
    review = build_review(:id, status: :rejected)

    assert_not review.valid?
    assert_includes review.errors[:base], 'No id proof found for review'

    paper_review = build_review(:id, status: :rejected, submission_method: :paper)

    assert paper_review.valid?, "Expected a rejected paper proof to be valid: #{paper_review.errors.full_messages}"
  end

  test 'a review with no proof type reports only the missing proof type' do
    review = ProofReview.new(application: @application, admin: @admin, status: :approved, reviewed_at: Time.current)

    assert_not review.valid?
    assert_includes review.errors[:proof_type], "can't be blank"
    assert_empty review.errors[:base]
  end

  private

  def attach(attachment, filename)
    attachment.attach(io: StringIO.new("#{filename} content"), filename: filename, content_type: 'application/pdf')
  end

  def build_review(proof_type, status: :approved, submission_method: nil)
    ProofReview.new(
      application: @application, admin: @admin, proof_type: proof_type, status: status, reviewed_at: Time.current,
      rejection_reason: status == :rejected ? 'Unreadable' : nil, submission_method: submission_method
    )
  end
end
