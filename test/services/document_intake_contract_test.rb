# frozen_string_literal: true

require 'test_helper'

# Shared intake checks for proof/certification writers and secure upload services.
# Each purpose keeps its own limit. A refused file must leave existing attachments unchanged.
class DocumentIntakeContractTest < ActiveSupport::TestCase
  ENTRY_POINTS = {
    proof_writer: :proof,
    certification_writer: :certification,
    secure_proof_form: :proof,
    secure_certification_form: :certification,
    secure_w9_form: :w9
  }.freeze

  setup do
    ensure_system_audit_actor!
    create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL) unless User.exists?(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
  end

  teardown do
    @tempfiles&.each(&:close!)
  end

  ENTRY_POINTS.each do |entry, purpose|
    test "#{entry} refuses a disguised executable" do
      assert_refused entry, :invalid_type, upload("MZ\x90\x00#{'x' * 4096}", 'proof.pdf')
    end

    test "#{entry} refuses a PDF with active content" do
      assert_refused entry, :suspicious_content, upload("%PDF-1.4\n/OpenAction << /S /JavaScript >>\n#{'x' * 4096}", 'form.pdf')
    end

    test "#{entry} refuses a file over its #{purpose} limit" do
      over = ProofUploadFormats.max_inclusive?(purpose) ? ProofUploadFormats.max_bytes(purpose) + 1 : ProofUploadFormats.max_bytes(purpose)
      assert_refused entry, :too_large, upload(pdf_bytes(over), 'large.pdf')
    end

    test "#{entry} accepts the largest #{purpose} file allowed" do
      largest = ProofUploadFormats.max_inclusive?(purpose) ? ProofUploadFormats.max_bytes(purpose) : ProofUploadFormats.max_bytes(purpose) - 1
      assert_accepted entry, upload(pdf_bytes(largest), 'largest.pdf')
    end

    test "#{entry} accepts a TIFF scan" do
      assert_accepted entry, upload("II*\x00#{'x' * 4096}", 'scan.tif', 'image/tiff')
    end

    test "#{entry} accepts a HEIC photo" do
      assert_accepted entry, upload("\x00\x00\x00\x18ftypheic#{'x' * 4096}", 'photo.heic', 'image/heic')
    end
  end

  private

  def assert_refused(entry, reason, file)
    submit = send(:"prepare_#{entry}")
    outcome = assert_no_difference('ActiveStorage::Attachment.count') { submit.call(file) }
    assert_equal reason, outcome, "#{entry} should refuse with #{reason}"
  end

  def assert_accepted(entry, file)
    assert_equal :accepted, send(:"prepare_#{entry}").call(file)
  end

  # Each prepare_ method creates the records first, so only the submission is measured.
  def prepare_proof_writer
    application = create(:application, :in_progress)
    lambda do |file|
      result = ProofAttachmentService.attach_proof(application: application, proof_type: :income, blob_or_file: file,
                                                   submission_method: :paper, status: :not_reviewed)
      result[:success] ? :accepted : refusal_reason(result[:error])
    end
  end

  def prepare_certification_writer
    application = create(:application, :in_progress)
    admin = create(:admin)
    lambda do |file|
      MedicalCertificationAttachmentService.attach_certification(application: application, blob_or_file: file, admin: admin,
                                                                 status: :received, submission_method: :admin_upload)
      :accepted
    rescue UploadedDocument::Refused => e
      e.reason
    end
  end

  def prepare_secure_proof_form
    application = create(:application, :in_progress)
    form = create(:secure_request_form, kind: :income_proof_resubmission, application: application)
    lambda do |file|
      secure_outcome(Applications::SubmitProofResubmission.new(application: application, secure_request_form: form,
                                                               file: file).call)
    end
  end

  def prepare_secure_certification_form
    application = create(:application, :in_progress, medical_provider_name: 'Dr. Provider',
                                                     medical_provider_email: 'provider@example.com')
    form = create(:medical_provider_secure_request_form, application: application)
    lambda do |file|
      secure_outcome(Applications::SubmitCertificationUpload.new(application: application,
                                                                 medical_provider_secure_request_form: form,
                                                                 file: file).call)
    end
  end

  def prepare_secure_w9_form
    vendor = create(:vendor, :with_w9)
    vendor.update!(w9_status: :rejected)
    form = create(:vendor_secure_request_form, vendor: vendor)
    lambda do |file|
      secure_outcome(Vendors::SubmitW9Resubmission.new(vendor: vendor, vendor_secure_request_form: form, file: file).call)
    end
  end

  def secure_outcome(result)
    return :accepted if result.success?

    errors = result.data&.dig(:errors)
    detail = errors.details[:file]&.first if errors
    detail ? detail[:error] : flunk("unexpected secure form failure: #{result.message}")
  end

  def refusal_reason(error)
    error.is_a?(UploadedDocument::Refused) ? error.reason : raise(error)
  end

  def pdf_bytes(size)
    header = "%PDF-1.4\n"
    header + ('x' * (size - header.bytesize))
  end

  def upload(bytes, filename, content_type = 'application/pdf')
    tempfile = Tempfile.new(['upload', File.extname(filename)])
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind
    (@tempfiles ||= []) << tempfile
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: filename, type: content_type)
  end
end
