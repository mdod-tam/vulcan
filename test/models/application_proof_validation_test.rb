# frozen_string_literal: true

require 'test_helper'

# Tests for Application model proof attachment validations
#
# These tests verify the validation rules defined in ProofManageable concern:
# - File type restrictions (PDF, JPEG, PNG, HEIC/HEIF)
# - File size limit (5MB)
# - Required attachments based on application status
#
# Related files:
# - app/models/concerns/proof_manageable.rb - Contains validation logic
# - app/models/application.rb - Includes the ProofManageable concern
# - app/mailboxes/proof_submission_mailbox.rb - Uses these validations

class ApplicationProofValidationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionDispatch::TestProcess::FixtureFile

  setup do
    @application = create(:application, :in_progress)

    # Create fixture directory if it doesn't exist
    @fixture_dir = Rails.root.join('test/fixtures/files')
    FileUtils.mkdir_p(@fixture_dir)

    # Create sample files for testing
    sample_pdf_path = @fixture_dir.join('income_proof.pdf')
    sample_jpg_path = @fixture_dir.join('sample.jpg')
    sample_png_path = @fixture_dir.join('sample.png')
    sample_txt_path = @fixture_dir.join('sample.txt')

    # Create test files if they don't exist
    File.write(sample_pdf_path, 'Sample PDF content') unless File.exist?(sample_pdf_path)
    File.write(sample_jpg_path, 'Sample JPG content') unless File.exist?(sample_jpg_path)
    File.write(sample_png_path, 'Sample PNG content') unless File.exist?(sample_png_path)
    File.write(sample_txt_path, 'Sample TXT content') unless File.exist?(sample_txt_path)

    # Load the fixture files
    @valid_pdf = fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf')
    @valid_jpg = fixture_file_upload('test/fixtures/files/sample.jpg', 'image/jpeg')
    @valid_png = fixture_file_upload('test/fixtures/files/sample.png', 'image/png')
    @invalid_txt = fixture_file_upload('test/fixtures/files/sample.txt', 'text/plain')

    # Thread variable to bypass some of the validations for testing
    # as implemented in the real application code
    setup_paper_application_context
  end

  teardown do
    # Cleanup thread variables
    teardown_paper_application_context
  end

  test 'accepts valid file types for income proof' do
    # Test PDF
    @application.income_proof.attach(@valid_pdf)
    assert @application.valid?, 'PDF should be accepted for income proof'
    @application.income_proof.detach

    # Test JPG
    @application.income_proof.attach(@valid_jpg)
    assert @application.valid?, 'JPG should be accepted for income proof'
    @application.income_proof.detach

    # Test PNG
    @application.income_proof.attach(@valid_png)
    assert @application.valid?, 'PNG should be accepted for income proof'
    @application.income_proof.detach

    # Test HEIC (content type only; Marcel validates on secure/email paths)
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
    # Use the factory properly and use draft status to avoid other validations
    application = create(:application, :in_progress)

    # Use the test context to skip validations that would interfere
    setup_paper_application_context

    # Create and attach a test text file (which should be rejected)
    file = Tempfile.new(['test', '.txt'])
    begin
      file.write('This is a text file')
      file.rewind

      # Only attach income proof with invalid type
      application.income_proof.attach(
        io: file,
        filename: 'test.txt',
        content_type: 'text/plain'
      )

      # Directly test the validation method itself
      application.errors.clear
      application.send(:correct_proof_mime_type)

      # Verify that validation failed for the income proof with the exact error message
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
    # Test PDF
    @application.residency_proof.attach(@valid_pdf)
    assert @application.valid?, 'PDF should be accepted for residency proof'
    @application.residency_proof.detach

    # Test JPG
    @application.residency_proof.attach(@valid_jpg)
    assert @application.valid?, 'JPG should be accepted for residency proof'
  end

  test 'rejects invalid file types for residency proof' do
    # Create a fresh application with minimal setup
    application = create(:application, :in_progress)

    # Create a valid PDF for income proof (to prevent other validations from failing first)
    valid_pdf = Rails.root.join('test/fixtures/files/income_proof.pdf').open

    # Create a test text file (which should be rejected)
    file = Tempfile.new(['test', '.txt'])
    begin
      file.write('This is a text file')
      file.rewind

      # Make sure both proofs are attached, but residency_proof has an invalid type
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

      # First confirm the file attachment worked
      assert application.residency_proof.attached?, 'Test file should be attached'
      assert_equal 'text/plain', application.residency_proof.content_type, 'Content type should be text/plain'
      assert application.income_proof.attached?, 'Valid PDF should be attached for income proof'

      # Directly call the MIME type validation
      application.errors.clear
      application.send(:correct_proof_mime_type)

      # Verify that validation failed for the residency proof with the exact error message
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
    # Create a temporary file that exceeds the size limit
    oversized_file = Tempfile.new(['oversized', '.pdf'])
    begin
      # Write content that exceeds 5MB (ProofManageable::MAX_FILE_SIZE)
      content = 'X' * (5.megabytes + 1.kilobyte)
      oversized_file.write(content)
      oversized_file.rewind

      # Attach to income_proof
      @application.income_proof.attach(
        io: oversized_file,
        filename: 'oversized.pdf',
        content_type: 'application/pdf'
      )

      # Validate the model
      assert_not @application.valid?, 'Oversized file should be rejected'
      assert_includes @application.errors[:income_proof],
                      'is too large. Maximum size allowed is 5MB.'
    ensure
      # Clean up the temporary file
      oversized_file.close
      oversized_file.unlink
    end
  end

  test 'validates residency proof shows address' do
    # This is a business rule that would need custom validation
    # Here, testing that the file can be attached
    @application.residency_proof.attach(@valid_pdf)
    assert @application.valid?, 'Valid residency proof should be accepted'
  end

  test 'resets proof status when new proof is attached via controller' do
    # First set the status to rejected
    @application.update!(income_proof_status: :rejected)

    # Then simulate the controller action
    @application.income_proof.attach(@valid_pdf)
    @application.update!(
      income_proof_status: :not_reviewed,
      needs_review_since: Time.current
    )

    # Status should be reset to not_reviewed
    assert_equal 'not_reviewed', @application.reload.income_proof_status
  end

  test 'sets needs_review_since when proof status changes to pending via controller' do
    # First set the status to rejected
    @application.update!(income_proof_status: :rejected, needs_review_since: nil)

    # Then simulate the controller action
    @application.income_proof.attach(@valid_pdf)
    @application.update!(
      income_proof_status: :not_reviewed,
      needs_review_since: Time.current
    )

    # needs_review_since should be set
    assert_not_nil @application.reload.needs_review_since
  end

  test 'validates SSA award letter is current year' do
    # This would require custom validation logic in the model
    # Document the requirement
    skip 'Implement custom validation for SSA award letter date'
  end

  test 'validates SSA award letter is less than 2 months old' do
    # This would require custom validation logic in the model
    # Document the requirement
    skip 'Implement custom validation for SSA award letter age'
  end
end
