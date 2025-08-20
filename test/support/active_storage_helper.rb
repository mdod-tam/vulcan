# frozen_string_literal: true

module ActiveStorageHelper
  # Setup clean storage directories for testing
  def setup_test_storage
    storage_dir = Rails.root.join('tmp/storage')
    FileUtils.rm_rf(storage_dir)
    FileUtils.mkdir_p(storage_dir)
  end

  # Clear Active Storage tables
  def clear_active_storage
    # First destroy all attachments
    ActiveStorage::Attachment.find_each(&:purge)

    # Then destroy all blobs
    ActiveStorage::Blob.find_each(&:purge)
  end

  # For use in test setup
  def setup_active_storage_test
    setup_test_storage
    clear_active_storage
  end

  # Disconnect any lingering connections to the test database
  def disconnect_test_database_connections
    ActiveRecord::Base.connection_pool.disconnect!

    # Reconnect to the database
    ActiveRecord::Base.establish_connection
  end

  # Helper to create and upload a blob directly (similar to our service implementation)
  def create_and_upload_blob(file, filename: nil, content_type: nil)
    filename ||= file.respond_to?(:original_filename) ? file.original_filename : File.basename(file)
    content_type ||= file.respond_to?(:content_type) ? file.content_type : 'application/octet-stream'

    ActiveStorage::Blob.create_and_upload!(
      io: file,
      filename: filename,
      content_type: content_type
    )
  end

  # Helper to attach a blob to a record
  def attach_blob_to(record, attachment_name, blob)
    record.send(attachment_name).attach(blob)
    record.send(attachment_name).reload

    # Verify attachment
    raise "Failed to attach blob to #{record.class.name}##{attachment_name}" unless record.send(attachment_name).attached?

    blob
  end
end
