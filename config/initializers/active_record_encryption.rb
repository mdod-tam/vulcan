# frozen_string_literal: true

Rails.application.configure do
  # Enable parameter filtering for encrypted columns
  config.active_record.encryption.add_to_filter_parameters = true

  # Disable extend_queries - causing issues in Rails 8.0
  # When false, queries must use the logical attribute names (email, phone)
  # and Rails will handle the translation to encrypted columns transparently
  config.active_record.encryption.extend_queries = false

  # Configure encryption keys from credentials (with fallback for missing credentials)
  encryption_config = Rails.application.credentials.active_record_encryption
  missing_keys = %i[primary_key deterministic_key key_derivation_salt].select { |name| encryption_config&.[](name).blank? }
  asset_build = ENV['SECRET_KEY_BASE_DUMMY'] == '1' && defined?(Rake) && Rake.application.top_level_tasks == ['assets:precompile']

  raise 'Persistent Active Record encryption credentials are required in production.' if Rails.env.production? && missing_keys.any? && !asset_build

  if encryption_config.present? && !(asset_build && missing_keys.any?)
    config.active_record.encryption.primary_key = encryption_config.primary_key
    config.active_record.encryption.deterministic_key = encryption_config.deterministic_key
    config.active_record.encryption.key_derivation_salt = encryption_config.key_derivation_salt
  else
    # Temporary keys are process-local for development/test or the exact Docker asset build.
    Rails.logger.warn '[ENCRYPTION] Active Record encryption credentials not found. Using temporary keys.'

    config.active_record.encryption.primary_key = SecureRandom.hex(32)
    config.active_record.encryption.deterministic_key = SecureRandom.hex(32)
    config.active_record.encryption.key_derivation_salt = SecureRandom.hex(32)
  end

  # Enable support for unencrypted data during transition
  # This allows reading both encrypted and unencrypted data
  config.active_record.encryption.support_unencrypted_data = true

  # Other encryption configuration
  config.active_record.encryption.encrypt_fixtures = true
  config.active_record.encryption.store_key_references = true
end
