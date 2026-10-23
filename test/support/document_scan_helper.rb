# frozen_string_literal: true

require_relative 'document_scan_fixtures'

module DocumentScanFixtures
  class ResponseStream < StringIO
    # The HTTP body reader omits length; StringIO needs one to signal EOF.
    def readpartial(length = 16_384)
      super
    end
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
