class AddCompositeIndexForDocumentSigning < ActiveRecord::Migration[8.0]
  def change
    # Composite index for faster webhook lookups by service + submission_id
    add_index :applications, %i[document_signing_service document_signing_submission_id],
              name: 'idx_apps_on_doc_signing_service_and_submission_id'
  end
end
