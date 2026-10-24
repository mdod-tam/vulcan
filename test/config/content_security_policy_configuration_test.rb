# frozen_string_literal: true

# Run the real initializer at fresh Rails startup without loading the database test helper.
require 'bundler/setup'
require 'minitest/autorun'
require 'active_support/test_case'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

class ContentSecurityPolicyConfigurationTest < ActiveSupport::TestCase
  SETTINGS = %w[S3_BUCKET BUCKETEER_BUCKET_NAME S3_REGION BUCKETEER_AWS_REGION].freeze
  INITIALIZER = File.expand_path('../../config/initializers/content_security_policy.rb', __dir__)
  STORAGE_INITIALIZER = File.expand_path('../../config/initializers/active_storage.rb', __dir__)
  FORMATS = File.expand_path('../../app/models/proof_upload_formats.rb', __dir__)
  STORAGE = File.expand_path('../../config/storage.yml', __dir__)
  BOOT_PROBE = <<~'RUBY'
    require 'rails'
    require 'action_controller/railtie'
    require 'json'
    require 'yaml'
    require 'erb'
    require 'net/http'
    require 'stringio'

    Net::HTTP.prepend(Module.new do
      def request(...)
        raise 'Network access is forbidden in the CSP boot probe'
      end
    end)

    class CspBootApplication < Rails::Application
      config.eager_load = false
      config.logger = Logger.new(StringIO.new)
      config.secret_key_base = 'synthetic-signing-key-for-isolated-csp-boot'
      config.paths['config/initializers'] = []
    end

    app = CspBootApplication.instance
    app.config.root = ENV.fetch('CSP_BOOT_ROOT')
    app.config.active_storage = ActiveSupport::OrderedOptions.new
    app.initializer('csp_under_test', before: 'load_config_initializers') do
      require ENV.fetch('CSP_BOOT_FORMATS')
      load ENV.fetch('CSP_BOOT_STORAGE_INITIALIZER')
      load ENV.fetch('CSP_BOOT_INITIALIZER')
    end

    begin
      app.initialize!
      storage = YAML.safe_load(ERB.new(File.read(ENV.fetch('CSP_BOOT_STORAGE'))).result).fetch('s3')
      result = { policy: app.config.content_security_policy.build, bucket: storage['bucket'], region: storage['region'],
                 download_expiry: app.config.active_storage.urls_expire_in.to_i }
      puts JSON.generate(result)
    rescue StandardError => error
      warn "#{error.class}: #{error.message}"
      exit 1
    end
  RUBY

  test 'absent storage settings permit same-origin startup without storage credentials' do
    %w[test development production].each do |environment|
      output, status = boot({}, environment)

      assert status.success?, output
      result = JSON.parse(output)
      assert_nil result.fetch('bucket')
      assert_equal 'us-east-1', result.fetch('region')
      assert_equal "connect-src 'self'", connection_directive(result)
      assert_equal 900, result.fetch('download_expiry')
    end
  end

  test 'direct and Bucketeer storage settings keep browser connections same-origin' do
    [%w[S3_BUCKET S3_REGION], %w[BUCKETEER_BUCKET_NAME BUCKETEER_AWS_REGION]].each do |bucket_key, region_key|
      output, status = boot(bucket_key => 'mat-upload-test', region_key => 'us-west-2')

      assert status.success?, output
      result = JSON.parse(output)
      assert_equal 'mat-upload-test', result.fetch('bucket')
      assert_equal 'us-west-2', result.fetch('region')
      assert_equal "connect-src 'self'", connection_directive(result)
    end
  end

  test 'default region and dotted bucket need no cross-origin browser sources' do
    output, status = boot('S3_BUCKET' => 'mat.upload.test')

    assert status.success?, output
    result = JSON.parse(output)
    assert_equal 'us-east-1', result.fetch('region')
    assert_equal "connect-src 'self'", connection_directive(result)
  end

  test 'bucket strings retain their type through storage YAML' do
    %w[123 off].each do |bucket|
      output, status = boot('S3_BUCKET' => bucket)

      assert status.success?, output
      result = JSON.parse(output)
      assert_equal bucket, result.fetch('bucket')
      assert_equal "connect-src 'self'", connection_directive(result)
    end
  end

  test 'GovCloud storage retains the same-origin browser policy' do
    output, status = boot('S3_BUCKET' => 'mat-upload-test', 'S3_REGION' => 'us-gov-west-1')

    assert status.success?, output
    result = JSON.parse(output)
    assert_equal 'us-gov-west-1', result.fetch('region')
    assert_equal "connect-src 'self'", connection_directive(result)
  end

  test 'invalid ordinary bucket names and reserved aliases fail during storage configuration' do
    %w[127.0.0.1 mat..upload.test xn--example sthree-example amzn-s3-demo-example
       example-s3alias example--ol-s3 example.mrap example--x-s3 example--table-s3].each do |bucket|
      output, status = boot('S3_BUCKET' => bucket)

      assert_not status.success?
      assert_includes output, 'Invalid S3 storage configuration: S3_BUCKET.'
      assert_not_includes output, bucket
    end
  end

  test 'unsupported AWS partitions fail clearly instead of permitting the wrong endpoint domain' do
    %w[cn-north-1 us-iso-east-1].each do |region|
      output, status = boot('S3_BUCKET' => 'mat-upload-test', 'S3_REGION' => region)

      assert_not status.success?
      assert_includes output, 'Invalid S3 storage configuration: S3_REGION.'
      assert_not_includes output, region
    end
  end

  test 'explicit malformed or blank selected settings fail at startup without disclosing values' do
    SETTINGS.each do |setting|
      ['', ' ', 'MalformedSettingSentinel/invalid'].each do |value|
        output, status = boot(setting => value)

        assert_not status.success?, "#{setting} must fail at startup"
        assert_includes output, "Invalid S3 storage configuration: #{setting}."
        assert_not_includes output, 'MalformedSettingSentinel'
      end
    end
  end

  test 'blank direct settings cannot silently select a valid Bucketeer fallback' do
    [%w[S3_BUCKET BUCKETEER_BUCKET_NAME mat-upload-test], %w[S3_REGION BUCKETEER_AWS_REGION us-west-2]].each do |direct, fallback, valid|
      output, status = boot(direct => '', fallback => valid)

      assert_not status.success?
      assert_includes output, "Invalid S3 storage configuration: #{direct}."
    end
  end

  test 'valid direct settings override unused malformed fallback values as storage does' do
    output, status = boot('S3_BUCKET' => 'mat-upload-test', 'S3_REGION' => 'us-west-2',
                          'BUCKETEER_BUCKET_NAME' => 'MalformedSettingSentinel/invalid',
                          'BUCKETEER_AWS_REGION' => 'MalformedSettingSentinel/invalid')

    assert status.success?, output
    result = JSON.parse(output)
    assert_equal 'mat-upload-test', result.fetch('bucket')
    assert_equal 'us-west-2', result.fetch('region')
    assert_not_includes result.fetch('policy'), 'MalformedSettingSentinel'
  end

  private

  def connection_directive(result)
    result.fetch('policy').split('; ').find { |directive| directive.start_with?('connect-src ') }
  end

  def boot(settings = {}, environment = 'test')
    Dir.mktmpdir('csp-boot') do |root|
      env = SETTINGS.index_with { nil }.merge(settings).merge(
        'CSP_BOOT_ROOT' => root, 'CSP_BOOT_INITIALIZER' => INITIALIZER, 'CSP_BOOT_STORAGE' => STORAGE,
        'CSP_BOOT_STORAGE_INITIALIZER' => STORAGE_INITIALIZER, 'CSP_BOOT_FORMATS' => FORMATS,
        'RAILS_ENV' => environment, 'DATABASE_URL' => nil
      )
      Open3.capture2e(env, RbConfig.ruby, '-e', BOOT_PROBE)
    end
  end
end
