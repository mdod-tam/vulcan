class AddDocumentSigningToApplications < ActiveRecord::Migration[8.0]
  def change
    change_table :applications, bulk: true do |t|
      t.integer  :document_signing_status, default: 0, null: false
      t.string   :document_signing_service # e.g. 'docuseal'
      t.string   :document_signing_submission_id
      t.string   :document_signing_submitter_id
      t.datetime :document_signing_requested_at
      t.datetime :document_signing_signed_at
      t.integer  :document_signing_request_count, default: 0, null: false
      t.text     :document_signing_audit_url
      t.text     :document_signing_document_url
    end

    add_index :applications, :document_signing_submission_id
    add_index :applications, :document_signing_service
    add_index :applications, :document_signing_status
  end
end
