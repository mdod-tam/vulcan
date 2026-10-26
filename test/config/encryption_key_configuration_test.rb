# frozen_string_literal: true

# This boot contract avoids test_helper, which truncates and seeds the database.
require 'bundler/setup'
require 'minitest/autorun'
require 'active_support/test_case'
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'tmpdir'

class EncryptionKeyConfigurationTest < ActiveSupport::TestCase
  KEY_NAMES = %w[primary_key deterministic_key key_derivation_salt].freeze
  INITIALIZER = File.expand_path('../../config/initializers/active_record_encryption.rb', __dir__)
  BOOT_PROBE = <<~'RUBY'
    require 'json'
    require 'rails'
    require 'active_record/railtie'
    require 'fileutils'
    require 'logger'
    require 'stringio'

    spec = JSON.parse(ENV.fetch('ENCRYPTION_BOOT_SPEC'))
    Object.const_set(:Rake, Module.new) if spec['partial_rake'] && !defined?(Rake)
    require 'propshaft' if spec['compile_assets']
    root = Pathname.new(ENV.fetch('ENCRYPTION_BOOT_ROOT'))
    Rails.env = spec.fetch('environment', 'production')
    credentials = ActiveSupport::OrderedOptions.new
    credentials.active_record_encryption = spec['keys']&.symbolize_keys
    credentials.secret_key_base = SecureRandom.hex(64)

    class EncryptionBootApplication < Rails::Application
      config.eager_load = false
      config.logger = Logger.new(StringIO.new)
      config.paths['config/initializers'] = []
    end

    app = EncryptionBootApplication.instance
    app.config.root = root
    app.define_singleton_method(:credentials) { credentials }
    app.config.define_singleton_method(:database_configuration) do
      { Rails.env => { 'adapter' => 'postgresql', 'database' => 'encryption_boot_unused' } }
    end
    app.initializer('encryption_guard_under_test', before: 'load_config_initializers') do
      load ENV.fetch('ENCRYPTION_BOOT_INITIALIZER')
    end

    # Reject connection checkout before a real database can be contacted.
    ActiveRecord::ConnectionAdapters::ConnectionPool.prepend(Module.new do
      def checkout(...)
        raise 'Database access is forbidden in the encryption boot probe'
      end
    end)

    begin
      if spec['tasks']
        require 'rake'
        Rake.application.init('rake', spec.fetch('tasks'))
        Rake::Task.define_task(:environment) { app.initialize! }
        if spec['compile_assets']
          FileUtils.mkdir_p(root.join('app/assets/builds'))
          File.write(root.join('app/assets/builds/application.css'), 'body { color: #123; }')
          load Gem::Specification.find_by_name('propshaft').full_gem_path + '/lib/propshaft/railties/assets.rake'
          Rake.application.top_level
        else
          app.initialize!
        end
      else
        app.initialize!
      end

      settings = app.config.active_record.encryption
      result = { 'keys' => settings.slice(:primary_key, :deterministic_key, :key_derivation_salt),
                 'support_unencrypted_data' => settings.support_unencrypted_data,
                 'assets' => Dir[root.join('public/assets/*').to_s].map { |path| File.basename(path) } }
      if spec['encrypt'] || spec['ciphertexts'] || spec['plaintext']
        types = [false, true].map do |deterministic|
          ActiveRecord::Encryption::EncryptedAttributeType.new(
            scheme: ActiveRecord::Encryption::Scheme.new(deterministic: deterministic)
          )
        end
        if spec['encrypt'] || spec['ciphertexts']
          result['ciphertexts'] = types.map { |type| type.serialize('synthetic test value') }
          result['decrypted'] = types.zip(spec['ciphertexts'] || result['ciphertexts']).map do |type, ciphertext|
            type.deserialize(ciphertext)
          end
        end
        if spec['plaintext']
          result['plaintext_rejected'] = types.map do |type|
            type.deserialize(spec['plaintext'])
            false
          rescue ActiveRecord::Encryption::Errors::Decryption
            true
          end
          result['absent_values'] = types.map { |type| type.deserialize(nil) }
        end
      end
      puts JSON.generate(result)
    rescue StandardError => error
      warn "#{error.class}: #{error.message}"
      exit 1
    end
  RUBY

  setup do
    @keys = KEY_NAMES.index_with { SecureRandom.hex(32) }
  end

  test 'persistent startup rejects absent and each missing or blank setting without printing values' do
    [nil, {}, *KEY_NAMES.flat_map { |name| [@keys.except(name), *[nil, '', ' '].map { |blank| @keys.merge(name => blank) }] }].each do |keys|
      output, status = boot(keys: keys)

      assert_not status.success?, 'Invalid runtime configuration must fail during initialization'
      missing = KEY_NAMES.select { |name| keys&.fetch(name, nil).blank? }
      assert_includes output, "Missing: #{missing.join(', ')}."
      @keys.each_value { |value| assert_not_includes output, value }
      assert_not_includes output, 'Database access is forbidden'
    end
  end

  test 'development and custom persistent environments also require saved keys' do
    %w[development staging].each do |environment|
      output, status = boot(environment: environment)

      assert_not status.success?
      assert_includes output, "credentials are required in #{environment}"
    end
  end

  test 'a partially loaded Rake module neither crashes startup nor permits a build exception' do
    output, status = boot(keys: @keys, partial_rake: true)
    assert status.success?, output
    assert_equal @keys, JSON.parse(output).fetch('keys')

    missing_output, missing_status = boot(partial_rake: true, dummy: '1')
    assert_not missing_status.success?
    assert_includes missing_output, 'Missing: primary_key, deterministic_key, key_derivation_salt.'
    assert_not_includes missing_output, 'NoMethodError'
  end

  test 'saved keys round-trip deterministic and nondeterministic ciphertext across fresh boots' do
    first, first_status = boot(keys: @keys, encrypt: true)
    assert first_status.success?, first
    encrypted = JSON.parse(first)
    assert_equal @keys, encrypted.fetch('keys')
    assert_equal false, encrypted.fetch('support_unencrypted_data')
    encrypted.fetch('ciphertexts').each { |value| assert_not_equal 'synthetic test value', value }

    second, second_status = boot(keys: @keys, ciphertexts: encrypted.fetch('ciphertexts'))
    assert second_status.success?, second
    assert_equal ['synthetic test value', 'synthetic test value'], JSON.parse(second).fetch('decrypted')
  end

  test 'encrypted attributes reject stored plaintext while allowing absent values' do
    %w[production test].each do |environment|
      output, status = boot(environment: environment, keys: @keys, plaintext: 'synthetic personal value')
      assert status.success?, output
      result = JSON.parse(output)

      assert_equal false, result.fetch('support_unencrypted_data')
      assert_equal [true, true], result.fetch('plaintext_rejected')
      assert_equal [nil, nil], result.fetch('absent_values')
    end
  end

  test 'disposable tests generate temporary keys but retain supplied complete keys' do
    [nil, @keys.slice('primary_key'), @keys].each do |keys|
      output, status = boot(environment: 'test', keys: keys, encrypt: true)
      assert status.success?, output
      result = JSON.parse(output)

      KEY_NAMES.each { |name| assert_match(/\A[0-9a-f]{64}\z/, result.fetch('keys').fetch(name)) }
      assert_equal @keys, result.fetch('keys') if keys == @keys
      assert_equal ['synthetic test value', 'synthetic test value'], result.fetch('decrypted')
    end
  end

  test 'sole production asset compilation succeeds without encryption keys or encrypted data access' do
    output, status = boot(tasks: ['assets:precompile'], compile_assets: true)
    assert status.success?, output
    result = JSON.parse(output.lines.last)

    assert_empty result.fetch('keys')
    assert result.fetch('assets').any? { |name| name.match?(/\Aapplication-[a-f0-9]+\.css\z/) }, result.inspect

    encrypted_output, encrypted_status = boot(tasks: ['assets:precompile'], encrypt: true)
    assert_not encrypted_status.success?
    assert_includes encrypted_output, 'Missing Active Record encryption credential'
  end

  test 'dummy signing key cannot bypass runtime or mixed asset and database tasks' do
    [nil, [], ['server'], ['solid_queue:start'], ['console'], ['db:migrate'], ['assets:precompile', 'db:migrate']].each do |tasks|
      output, status = boot(tasks: tasks, dummy: '1')

      assert_not status.success?, "Runtime context #{tasks.inspect} must require saved keys"
      assert_includes output, 'Missing: primary_key, deterministic_key, key_derivation_salt.'
    end
  end

  private

  def boot(**spec)
    Dir.mktmpdir('encryption-boot') do |root|
      env = {
        'ENCRYPTION_BOOT_SPEC' => JSON.generate(spec),
        'ENCRYPTION_BOOT_ROOT' => root,
        'ENCRYPTION_BOOT_INITIALIZER' => INITIALIZER,
        'RAILS_ENV' => spec.fetch(:environment, 'production'),
        'SECRET_KEY_BASE_DUMMY' => spec[:dummy],
        'SECRET_KEY_BASE' => nil,
        'RAILS_MASTER_KEY' => nil,
        'DATABASE_URL' => nil
      }
      Open3.capture2e(env, RbConfig.ruby, '-e', BOOT_PROBE)
    end
  end
end
