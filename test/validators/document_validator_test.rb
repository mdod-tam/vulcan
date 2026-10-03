# frozen_string_literal: true

require 'test_helper'

class DocumentValidatorTest < ActiveSupport::TestCase
  setup do
    @application = create(:application, :in_progress)
  end

  test 'a newly attached file of a disallowed type is invalid' do
    @application.income_proof.attach(io: StringIO.new('plain notes'), filename: 'notes.txt', content_type: 'text/plain')

    assert_not @application.valid?
    assert_includes @application.errors[:income_proof], "must be a PDF or an image file (#{ProofUploadFormats::HUMAN_LABEL})"
  end

  test 'a newly attached certification over its limit is invalid' do
    @application.medical_certification.attach(blob(ProofUploadFormats.max_bytes(:certification) + 1))

    assert_not @application.valid?
    assert_includes @application.errors[:medical_certification], 'is too large. Maximum size allowed is 10MB.'
  end

  test 'a stored document is not re-judged on an unrelated save' do
    @application.income_proof.attach(blob(ProofUploadFormats::PROOF_MAX_BYTES + 1))
    @application.save!(validate: false)

    @application.reload.update!(household_size: @application.household_size + 1)

    assert_equal ProofUploadFormats::PROOF_MAX_BYTES + 1, @application.income_proof.blob.byte_size
  end

  test 'a provider-generated certification keeps its own contract' do
    generated = blob(ProofUploadFormats.max_bytes(:certification) + 1, metadata: { 'source' => 'docuseal' })

    @application.additional_medical_certifications.attach(generated)

    assert_predicate @application, :valid?
    assert_includes @application.reload.additional_medical_certifications.blobs, generated
  end

  private

  def blob(size, metadata: {})
    header = "%PDF-1.4\n"
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(header + ('x' * (size - header.bytesize))),
                                           filename: 'document.pdf', content_type: 'application/pdf', metadata: metadata)
  end
end
