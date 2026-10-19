# frozen_string_literal: true

require 'test_helper'
require 'rake'

class EncryptionKeyConfigurationTest < ActiveSupport::TestCase
  PERSISTENT_KEYS = {
    primary_key: 'saved-primary-key',
    deterministic_key: 'saved-deterministic-key',
    key_derivation_salt: 'saved-key-derivation-salt'
  }.freeze

  setup do
    @original_encryption_settings = Rails.application.config.active_record.encryption.to_h.deep_dup
    @original_dummy = ENV.fetch('SECRET_KEY_BASE_DUMMY', nil)
    ENV.delete('SECRET_KEY_BASE_DUMMY')
  end

  teardown do
    Rails.application.config.active_record.encryption.replace(@original_encryption_settings)
    if @original_dummy.nil?
      ENV.delete('SECRET_KEY_BASE_DUMMY')
    else
      ENV['SECRET_KEY_BASE_DUMMY'] = @original_dummy
    end
  end

  test 'production refuses temporary encryption keys when credentials are absent' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
    Rails.application.credentials.stubs(:active_record_encryption).returns(nil)

    error = assert_raises(RuntimeError) { load Rails.root.join('config/initializers/active_record_encryption.rb') }

    assert_equal 'Persistent Active Record encryption credentials are required in production. ' \
                 'Missing: primary_key, deterministic_key, key_derivation_salt. ' \
                 'Configure them with bin/rails credentials:edit --environment production.', error.message
  end

  test 'production refuses partially configured persistent encryption keys' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
    PERSISTENT_KEYS.each_key do |missing|
      keys = PERSISTENT_KEYS.except(missing)
      Rails.application.credentials.stubs(:active_record_encryption).returns(keys)

      assert_raises(RuntimeError, "#{missing} must be configured before production boot") do
        load Rails.root.join('config/initializers/active_record_encryption.rb')
      end
    end
  end

  test 'production refuses blank persistent encryption key entries' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
    PERSISTENT_KEYS.each_key do |missing|
      keys = PERSISTENT_KEYS.merge(missing => ' ')
      Rails.application.credentials.stubs(:active_record_encryption).returns(keys)

      assert_raises(RuntimeError) { load_initializer }
    end
  end

  test 'only an explicit dummy-key asset precompile may use temporary production encryption keys' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
    Rails.application.credentials.stubs(:active_record_encryption).returns(nil)
    ENV['SECRET_KEY_BASE_DUMMY'] = '1'
    Rake.application.stubs(:top_level_tasks).returns(['assets:precompile'])

    load_initializer

    settings = Rails.application.config.active_record.encryption
    PERSISTENT_KEYS.each_key do |key|
      assert_match(/\A[0-9a-f]{64}\z/, settings[key])
    end
  end

  test 'asset precompile with partial credentials uses temporary build-only keys' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
    Rails.application.credentials.stubs(:active_record_encryption).returns({ primary_key: 'partial-setting' })
    ENV['SECRET_KEY_BASE_DUMMY'] = '1'
    Rake.application.stubs(:top_level_tasks).returns(['assets:precompile'])

    load_initializer

    assert_not_equal 'partial-setting', Rails.application.config.active_record.encryption.primary_key
    assert Rails.application.config.active_record.encryption.deterministic_key.present?
  end

  test 'dummy key alone does not permit runtime, release tasks, or combined asset and database tasks' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
    Rails.application.credentials.stubs(:active_record_encryption).returns(nil)
    ENV['SECRET_KEY_BASE_DUMMY'] = '1'
    [[], ['server'], ['jobs:work'], ['console'], ['db:migrate'], ['assets:precompile', 'db:migrate']].each do |tasks|
      Rake.application.stubs(:top_level_tasks).returns(tasks)

      assert_raises(RuntimeError, "Runtime tasks #{tasks.inspect} must require persistent keys") { load_initializer }
    end
  end

  test 'asset precompile without explicit dummy key still requires persistent production keys' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))
    Rails.application.credentials.stubs(:active_record_encryption).returns(nil)
    Rake.application.stubs(:top_level_tasks).returns(['assets:precompile'])

    assert_raises(RuntimeError) { load_initializer }
  end

  test 'development and custom runtimes refuse missing or empty persistent credentials' do
    %w[development staging].each do |environment|
      Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new(environment))
      [nil, {}].each do |keys|
        Rails.application.credentials.stubs(:active_record_encryption).returns(keys)

        error = assert_raises(RuntimeError) { load_initializer }

        assert_includes error.message, "Persistent Active Record encryption credentials are required in #{environment}."
        assert_includes error.message, 'Missing: primary_key, deterministic_key, key_derivation_salt.'
        assert_includes error.message, "bin/rails credentials:edit --environment #{environment}."
        assert_equal @original_encryption_settings.slice(*PERSISTENT_KEYS.keys),
                     Rails.application.config.active_record.encryption.to_h.slice(*PERSISTENT_KEYS.keys)
      end
    end
  end

  test 'development refuses each missing or blank persistent key' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('development'))
    PERSISTENT_KEYS.each_key do |missing|
      incomplete = [PERSISTENT_KEYS.except(missing)]
      incomplete.concat([nil, '', ' '].map { |blank| PERSISTENT_KEYS.merge(missing => blank) })
      incomplete.each do |keys|
        Rails.application.credentials.stubs(:active_record_encryption).returns(keys)

        error = assert_raises(RuntimeError) { load_initializer }

        assert_includes error.message, "Missing: #{missing}."
      end
    end
  end

  test 'complete saved keys are retained unchanged in persistent and test environments' do
    Rails.application.credentials.stubs(:active_record_encryption).returns(PERSISTENT_KEYS)
    %w[development staging production test].each do |environment|
      Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new(environment))

      load_initializer

      assert_equal PERSISTENT_KEYS, Rails.application.config.active_record.encryption.to_h.slice(*PERSISTENT_KEYS.keys)
    end
  end

  test 'disposable test runtime replaces missing or incomplete credentials with a full temporary key set' do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('test'))
    [nil, {}, PERSISTENT_KEYS.slice(:primary_key), PERSISTENT_KEYS.merge(primary_key: ' ')].each do |keys|
      Rails.application.credentials.stubs(:active_record_encryption).returns(keys)

      load_initializer

      PERSISTENT_KEYS.each_key do |key|
        assert_match(/\A[0-9a-f]{64}\z/, Rails.application.config.active_record.encryption[key])
      end
    end
  end

  private

  def load_initializer
    load Rails.root.join('config/initializers/active_record_encryption.rb')
  end
end
