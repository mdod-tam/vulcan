# frozen_string_literal: true

require 'test_helper'
require 'rake'

class EncryptionKeyConfigurationTest < ActiveSupport::TestCase
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
    Rails.env.stubs(:production?).returns(true)
    Rails.application.credentials.stubs(:active_record_encryption).returns(nil)

    error = assert_raises(RuntimeError) { load Rails.root.join('config/initializers/active_record_encryption.rb') }

    assert_equal 'Persistent Active Record encryption credentials are required in production.', error.message
  end

  test 'production refuses partially configured persistent encryption keys' do
    Rails.env.stubs(:production?).returns(true)
    required = %i[primary_key deterministic_key key_derivation_salt]
    required.each do |missing|
      keys = required.index_with { 'configured-test-key' }.except(missing)
      Rails.application.credentials.stubs(:active_record_encryption).returns(keys)

      assert_raises(RuntimeError, "#{missing} must be configured before production boot") do
        load Rails.root.join('config/initializers/active_record_encryption.rb')
      end
    end
  end

  test 'production refuses blank persistent encryption key entries' do
    Rails.env.stubs(:production?).returns(true)
    required = %i[primary_key deterministic_key key_derivation_salt]
    required.each do |missing|
      keys = required.index_with { 'configured-test-key' }.merge(missing => ' ')
      Rails.application.credentials.stubs(:active_record_encryption).returns(keys)

      assert_raises(RuntimeError) { load_initializer }
    end
  end

  test 'only an explicit dummy-key asset precompile may use temporary production encryption keys' do
    Rails.env.stubs(:production?).returns(true)
    Rails.application.credentials.stubs(:active_record_encryption).returns(nil)
    ENV['SECRET_KEY_BASE_DUMMY'] = '1'
    Rake.application.stubs(:top_level_tasks).returns(['assets:precompile'])

    load_initializer

    settings = Rails.application.config.active_record.encryption
    %i[primary_key deterministic_key key_derivation_salt].each do |key|
      assert_match(/\A[0-9a-f]{64}\z/, settings[key])
    end
  end

  test 'asset precompile with partial credentials uses temporary build-only keys' do
    Rails.env.stubs(:production?).returns(true)
    Rails.application.credentials.stubs(:active_record_encryption).returns({ primary_key: 'partial-setting' })
    ENV['SECRET_KEY_BASE_DUMMY'] = '1'
    Rake.application.stubs(:top_level_tasks).returns(['assets:precompile'])

    load_initializer

    assert_not_equal 'partial-setting', Rails.application.config.active_record.encryption.primary_key
    assert Rails.application.config.active_record.encryption.deterministic_key.present?
  end

  test 'dummy key alone does not permit runtime, release tasks, or combined asset and database tasks' do
    Rails.env.stubs(:production?).returns(true)
    Rails.application.credentials.stubs(:active_record_encryption).returns(nil)
    ENV['SECRET_KEY_BASE_DUMMY'] = '1'
    [[], ['server'], ['jobs:work'], ['console'], ['db:migrate'], ['assets:precompile', 'db:migrate']].each do |tasks|
      Rake.application.stubs(:top_level_tasks).returns(tasks)

      assert_raises(RuntimeError, "Runtime tasks #{tasks.inspect} must require persistent keys") { load_initializer }
    end
  end

  test 'asset precompile without explicit dummy key still requires persistent production keys' do
    Rails.env.stubs(:production?).returns(true)
    Rails.application.credentials.stubs(:active_record_encryption).returns(nil)
    Rake.application.stubs(:top_level_tasks).returns(['assets:precompile'])

    assert_raises(RuntimeError) { load_initializer }
  end

  private

  def load_initializer
    load Rails.root.join('config/initializers/active_record_encryption.rb')
  end
end
