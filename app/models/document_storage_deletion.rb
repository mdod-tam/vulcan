# frozen_string_literal: true

# Keeps the storage key after its blob is removed, until deletion succeeds.
class DocumentStorageDeletion < ApplicationRecord
  def purge!
    with_lock do
      ActiveStorage::Blob.new(key: key, service_name: service_name, content_type: content_type).delete
      destroy!
    end
  rescue ActiveRecord::RecordNotFound
    # Another cleanup worker completed this deletion.
    nil
  end
end
