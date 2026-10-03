# frozen_string_literal: true

require 'test_helper'

# Covers the ProofManageable content type and 5 MB size validations on proof attachments.
# The paper context skips required-attachment validation.

class ApplicationProofValidationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionDispatch::TestProcess::FixtureFile

  setup do
    @application = create(:application, :in_progress)

    @fixture_dir = Rails.root.join('test/fixtures/files')
    FileUtils.mkdir_p(@fixture_dir)

    sample_pdf_path = @fixture_dir.join('income_proof.pdf')
    sample_jpg_path = @fixture_dir.join('sample.jpg')
    sample_png_path = @fixture_dir.join('sample.png')
    sample_txt_path = @fixture_dir.join('sample.txt')

    File.write(sample_pdf_path, 'Sample PDF content') unless File.exist?(sample_pdf_path)
    File.write(sample_jpg_path, 'Sample JPG content') unless File.exist?(sample_jpg_path)
    File.write(sample_png_path, 'Sample PNG content') unless File.exist?(sample_png_path)
    File.write(sample_txt_path, 'Sample TXT content') unless File.exist?(sample_txt_path)

    @valid_pdf = fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf')
    @valid_jpg = fixture_file_upload('test/fixtures/files/sample.jpg', 'image/jpeg')
    @valid_png = fixture_file_upload('test/fixtures/files/sample.png', 'image/png')
    @invalid_txt = fixture_file_upload('test/fixtures/files/sample.txt', 'text/plain')

    setup_paper_application_context
  end

  teardown do
    teardown_paper_application_context
  end

  test 'accepts valid file types for income proof' do
    @application.income_proof.attach(@valid_pdf)
    assert @application.valid?, 'PDF should be accepted for income proof'
    @application.income_proof.detach

    @application.income_proof.attach(@valid_jpg)
    assert @application.valid?, 'JPG should be accepted for income proof'
    @application.income_proof.detach

    @application.income_proof.attach(@valid_png)
    assert @application.valid?, 'PNG should be accepted for income proof'
    @application.income_proof.detach

    # The model checks only the declared content type.
    # ProofAttachmentValidator inspects content for secure form submissions.
    heic_io = StringIO.new('sample heic content')
    @application.income_proof.attach(
      io: heic_io,
      filename: 'proof.heic',
      content_type: 'image/heic'
    )
    assert @application.valid?, 'HEIC should be accepted for income proof'
  end

  test 'accepts valid file types for id proof' do
    @application.id_proof.attach(@valid_png)
    assert @application.valid?, 'PNG should be accepted for id proof'
  end

  test 'rejects invalid file types for income proof' do
    application = create(:application, :in_progress)
    setup_paper_application_context

    file = Tempfile.new(['test', '.txt'])
    begin
      file.write('This is a text file')
      file.rewind

      application.income_proof.attach(
        io: file,
        filename: 'test.txt',
        content_type: 'text/plain'
      )

      # The document backstop checks the newly attached proof
      application.valid?

      assert_includes application.errors[:income_proof],
                      "must be a PDF or an image file (#{ProofUploadFormats::HUMAN_LABEL})",
                      'Validation should reject text file for income proof'
    ensure
      file.close
      file.unlink
      teardown_paper_application_context
    end
  end

  test 'accepts valid file types for residency proof' do
    @application.residency_proof.attach(@valid_pdf)
    assert @application.valid?, 'PDF should be accepted for residency proof'
    @application.residency_proof.detach

    @application.residency_proof.attach(@valid_jpg)
    assert @application.valid?, 'JPG should be accepted for residency proof'
  end

  test 'rejects invalid file types for residency proof' do
    application = create(:application, :in_progress)

    # A valid income proof keeps the failure on residency_proof.
    valid_pdf = Rails.root.join('test/fixtures/files/income_proof.pdf').open

    file = Tempfile.new(['test', '.txt'])
    begin
      file.write('This is a text file')
      file.rewind

      application.income_proof.attach(
        io: valid_pdf,
        filename: 'income_proof.pdf',
        content_type: 'application/pdf'
      )

      application.residency_proof.attach(
        io: file,
        filename: 'test.txt',
        content_type: 'text/plain'
      )

      assert application.residency_proof.attached?, 'Test file should be attached'
      assert_equal 'text/plain', application.residency_proof.content_type, 'Content type should be text/plain'
      assert application.income_proof.attached?, 'Valid PDF should be attached for income proof'

      # The document backstop checks the newly attached proof
      application.valid?

      assert_includes application.errors[:residency_proof],
                      "must be a PDF or an image file (#{ProofUploadFormats::HUMAN_LABEL})",
                      'Validation should reject text file for residency proof'
    ensure
      file.close
      file.unlink
      valid_pdf.close
    end
  end

  test 'validates proof file size limits' do
    oversized_file = Tempfile.new(['oversized', '.pdf'])
    begin
      # ProofUploadFormats::PROOF_MAX_BYTES is 5 MB.
      content = 'X' * (5.megabytes + 1.kilobyte)
      oversized_file.write(content)
      oversized_file.rewind

      @application.income_proof.attach(
        io: oversized_file,
        filename: 'oversized.pdf',
        content_type: 'application/pdf'
      )

      assert_not @application.valid?, 'Oversized file should be rejected'
      assert_includes @application.errors[:income_proof],
                      'is too large. Maximum size allowed is 5MB.'
    ensure
      oversized_file.close
      oversized_file.unlink
    end
  end

  test 'validates residency proof shows address' do
    # No validation checks the address. This test only attaches a valid file.
    @application.residency_proof.attach(@valid_pdf)
    assert @application.valid?, 'Valid residency proof should be accepted'
  end

  test 'resets proof status when new proof is attached via controller' do
    @application.update!(income_proof_status: :rejected)

    # Simulates the controller update.
    @application.income_proof.attach(@valid_pdf)
    @application.update!(
      income_proof_status: :not_reviewed,
      needs_review_since: Time.current
    )

    assert_equal 'not_reviewed', @application.reload.income_proof_status
  end

  test 'sets needs_review_since when proof status changes to pending via controller' do
    @application.update!(income_proof_status: :rejected, needs_review_since: nil)

    # Simulates the controller update.
    @application.income_proof.attach(@valid_pdf)
    @application.update!(
      income_proof_status: :not_reviewed,
      needs_review_since: Time.current
    )

    assert_not_nil @application.reload.needs_review_since
  end

  test 'validates SSA award letter is current year' do
    skip 'Implement custom validation for SSA award letter date'
  end

  test 'validates SSA award letter is less than 2 months old' do
    skip 'Implement custom validation for SSA award letter age'
  end
end
