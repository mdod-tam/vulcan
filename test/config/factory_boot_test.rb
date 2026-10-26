# frozen_string_literal: true

require 'bundler/setup'
require 'active_support/test_case'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'

class FactoryBootTest < ActiveSupport::TestCase
  BOOT_PROBE = <<~'RUBY'
    require_relative 'config/environment'
    raise 'General test helpers were loaded' if defined?(DocumentScanHelper)

    ActiveRecord::Base.transaction(requires_new: true) do
      identity = SecureRandom.uuid
      vendor = FactoryBot.create(:vendor_user, email: "factory-boot-#{identity}@example.test")
      raise 'Vendor fixture is not cleared' unless DocumentScan.cleared?(vendor.w9_form.blob)

      other_vendor = FactoryBot.create(:vendor, :with_w9, email: "factory-boot-other-#{identity}@example.test")
      raise 'W9 trait is not cleared' unless DocumentScan.cleared?(other_vendor.w9_form.blob)

      constituent = FactoryBot.create(:constituent, email: "factory-boot-applicant-#{identity}@example.test", phone: '202-555-9841')
      application = FactoryBot.create(:application, :with_rejected_proofs, user: constituent)
      %i[income_proof residency_proof].each do |slot|
        blob = application.public_send(slot).blob
        scan = DocumentScan.find_by!(blob: blob)
        raise "#{slot} fixture is not cleared for its owner" unless scan.clean? && scan.user_id == constituent.id
      end
      raise ActiveRecord::Rollback
    end
    puts 'Bare Rails factories preserve fixture clearance'
  RUBY

  test 'document factories load their fixture dependency without test_helper' do
    output, error, status = Open3.capture3(
      { 'RAILS_ENV' => 'test' }, RbConfig.ruby, '-e', BOOT_PROBE, chdir: File.expand_path('../..', __dir__)
    )

    assert status.success?, "Bare Rails factory probe failed:\n#{output}\n#{error}"
    assert_includes output, 'Bare Rails factories preserve fixture clearance'
  end
end
