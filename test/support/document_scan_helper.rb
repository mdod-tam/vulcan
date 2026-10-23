# frozen_string_literal: true

module DocumentScanFixtures
  class ResponseStream < StringIO
    # The HTTP body reader omits length; StringIO needs one to signal EOF.
    def readpartial(length = 16_384)
      super
    end
  end

  def self.clear!(blob, user:, secure_form: nil, purpose: :proof, slot: 'income_proof', fixture: nil)
    sha256 = fixture ? Digest::SHA256.file(Rails.root.join('test/fixtures/files', fixture)).hexdigest : Digest::SHA256.hexdigest(blob.download)
    scan = DocumentScan.find_or_initialize_by(blob: blob)
    scan.assign_attributes(user: user, secure_form: secure_form,
                           purpose: purpose, slot: slot, sha256: sha256,
                           status: :clean, completed_at: Time.current)
    scan.save!
    blob
  end
end

module DocumentScanHelper
  # Tests that exercise a later boundary start with a known scanner result.
  def mark_document_clean!(blob, user: nil, secure_form: nil, purpose: :proof, slot: 'income_proof')
    DocumentScanFixtures.clear!(blob, user: user || (secure_form ? nil : create(:constituent)),
                                      secure_form: secure_form, purpose: purpose, slot: slot)
  end

  def scanned_upload(file, user: nil, secure_form: nil, purpose: :proof, slot: 'income_proof')
    scan = DocumentScan.stage!(input: file, user: user, secure_form: secure_form, purpose: purpose, slot: slot)
    scan.update!(status: :clean, completed_at: Time.current)
    scan.blob
  end
end

ActiveSupport.on_load(:active_support_test_case) { include DocumentScanHelper }
