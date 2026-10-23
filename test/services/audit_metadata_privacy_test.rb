# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
require 'active_support/all'
require 'active_support/test_case'
require_relative '../../app/services/audit_metadata_privacy'

class AuditMetadataPrivacyTest < ActiveSupport::TestCase
  test 'projects each live change shape without mutating the input' do
    metadata = { changes: { email: { old: 'alice@example.com', new: 'bob@agency.org' },
                            phone: %w[410-555-1234 202-555-5678],
                            date_of_birth: { from: '1980-01-02', to: '1981-03-04' },
                            physical_address_1: [nil, '123 Private Lane'], zip_code: %w[21201 21202],
                            first_name: { old: 'Alice', new: 'Anne' }, hearing_disability: [true, false] },
                 provider_email: 'doctor@provider.test', request_id: 'request-123' }
    original = metadata.deep_dup
    result = AuditMetadataPrivacy.new.filter(metadata)

    assert_equal({ old: 'a***@e***.com', new: 'b***@a***.org' }, result[:changes][:email])
    assert_equal ['***-***-1234', '***-***-5678'], result[:changes][:phone]
    assert_equal({ from: '[withheld]', to: '[withheld]' }, result[:changes][:date_of_birth])
    assert_equal [nil, '[withheld]'], result[:changes][:physical_address_1]
    assert_equal ['[withheld]', '[withheld]'], result[:changes][:zip_code]
    assert_equal({ old: 'A***', new: 'A***' }, result[:changes][:first_name])
    assert_equal [true, false], result[:changes][:hearing_disability]
    assert_equal 'd***@p***.test', result[:provider_email]
    assert_equal 'request-123', result[:request_id]
    assert_equal original, metadata
    assert_equal result, AuditMetadataPrivacy.new.filter(result)
  end

  test 'secrets retain no fragments and malformed contacts fail closed' do
    result = AuditMetadataPrivacy.new.filter(password_digest: 'bcrypt-secret', raw_token: 'bearer-value',
                                             secure_upload_url: 'https://example.test/secret', email: 'invalid',
                                             phone: '123', first_name: '李', last_name: '')
    %i[password_digest raw_token secure_upload_url email phone].each { |field| assert_equal '[withheld]', result[field] }
    assert_equal '李***', result[:first_name]
    assert_equal '', result[:last_name]
  end

  test 'encrypted attributes supplement classification and preserve encrypted device history' do
    model = Class.new do
      def self.encrypted_attributes
        Set.new(%w[new_private_attribute serial_number])
      end
    end
    privacy = AuditMetadataPrivacy.new(auditable: model.new)
    changes = privacy.filter(changes: { new_private_attribute: %w[before after], serial_number: %w[SERIAL-A SERIAL-B] })[:changes]

    assert_equal ['[withheld]', '[withheld]'], changes[:new_private_attribute]
    assert_equal %w[SERIAL-A SERIAL-B], changes[:serial_number]
  end

  test 'nested record collections classify their fields without changing structure or the input' do
    metadata = { candidates: [{ user_id: 42, role: 'guardian', email: 'alice@example.com',
                                contact: { phone: '410-555-1234', assigned_to_name: 'Alice Smith' },
                                changes: { date_of_birth: { from: '1980-01-02', to: '1981-03-04' },
                                           active: [true, false] } },
                              ['kept', { provider_email: 'doctor@agency.org' }]] }
    original = metadata.deep_dup
    privacy = AuditMetadataPrivacy.new
    result = privacy.filter(metadata)

    assert_equal({ candidates: [{ user_id: 42, role: 'guardian', email: 'a***@e***.com',
                                  contact: { phone: '***-***-1234', assigned_to_name: 'A*** S***' },
                                  changes: { date_of_birth: { from: '[withheld]', to: '[withheld]' },
                                             active: [true, false] } },
                                ['kept', { provider_email: 'd***@a***.org' }]] }, result)
    assert_equal original, metadata
    assert_equal result, privacy.filter(result)
  end

  test 'sensitive wrappers protect nested leaves as well as old-new and from-to values' do
    metadata = { raw_token: { value: 'secret-one', nested: [{ label: 'secret-two' }] },
                 rationale: [{ explanation: 'Private decision', absent: nil, confirmed: false }],
                 email: { old: 'alice@example.com', new: 'bob@agency.org' },
                 changes: { phone: { from: nil, to: '410-555-1234' }, first_name: %w[Alice Anne] } }
    original = metadata.deep_dup
    privacy = AuditMetadataPrivacy.new
    result = privacy.filter(metadata)

    assert_equal({ raw_token: { value: '[withheld]', nested: [{ label: '[withheld]' }] },
                   rationale: [{ explanation: '[withheld]', absent: nil, confirmed: false }],
                   email: { old: 'a***@e***.com', new: 'b***@a***.org' },
                   changes: { phone: { from: nil, to: '***-***-1234' }, first_name: %w[A*** A***] } }, result)
    assert_equal original, metadata
    assert_equal result, privacy.filter(result)
  end
end
