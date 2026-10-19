# frozen_string_literal: true

Rails.application.configure do
  # Enable parameter filtering for encrypted columns
  config.active_record.encryption.add_to_filter_parameters = true

  # Disable extend_queries - causing issues in Rails 8.0
  # When false, queries must use the logical attribute names (email, phone)
  # and Rails will handle the translation to encrypted columns transparently
  config.active_record.encryption.extend_queries = false

  # Persistent environments must reuse saved encryption credentials.
  encryption_config = Rails.application.credentials.active_record_encryption
  missing_keys = %i[primary_key deterministic_key key_derivation_salt].select { |name| encryption_config&.[](name).blank? }
  asset_build = ENV['SECRET_KEY_BASE_DUMMY'] == '1' && defined?(Rake) && Rake.application.top_level_tasks == ['assets:precompile']

  if missing_keys.any? && !Rails.env.test? && !asset_build
    raise "Persistent Active Record encryption credentials are required in #{Rails.env}. " \
          "Missing: #{missing_keys.join(', ')}. " \
          "Configure them with bin/rails credentials:edit --environment #{Rails.env}."
  end

  if missing_keys.empty?
    config.active_record.encryption.primary_key = encryption_config[:primary_key]
    config.active_record.encryption.deterministic_key = encryption_config[:deterministic_key]
    config.active_record.encryption.key_derivation_salt = encryption_config[:key_derivation_salt]
  else
    # Temporary keys are process-local for tests or the exact Docker asset build.
    Rails.logger.warn '[ENCRYPTION] Using temporary encryption keys for tests or asset precompilation.'

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
