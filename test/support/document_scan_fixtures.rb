# frozen_string_literal: true

require 'digest'

module DocumentScanFixtures
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
