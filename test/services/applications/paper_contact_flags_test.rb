# frozen_string_literal: true

require 'test_helper'

module Applications
  class PaperContactFlagsTest < ActiveSupport::TestCase
    test 'constituent no-contact flags clear contact and force letter delivery' do
      flags = PaperContactFlags.new(
        { no_email_address: '1', no_phone_number: '1' },
        scope: :constituent
      )

      normalized = flags.apply_to(
        email: 'ignored@example.com',
        phone: '410-555-0100',
        phone_type: 'voice',
        communication_preference: 'email'
      )

      assert_nil normalized[:email]
      assert_nil normalized[:phone]
      assert_equal 'letter', normalized[:phone_type]
      assert_equal 'letter', normalized[:communication_preference]
      assert flags.skip_email_validation?
      assert flags.skip_phone_validation?
    end

    test 'no-phone flag keeps email-only preferred contact method as email' do
      flags = PaperContactFlags.new({ no_phone_number: '1' }, scope: :constituent)

      normalized = flags.apply_to(
        email: 'email-only@example.com',
        phone: '410-555-0101',
        phone_type: 'voice',
        communication_preference: 'email'
      )

      assert_equal 'email-only@example.com', normalized[:email]
      assert_nil normalized[:phone]
      assert_equal 'email', normalized[:phone_type]
      assert_equal 'email', normalized[:communication_preference]
    end

    test 'guardian flags are independent from constituent flags' do
      guardian_flags = PaperContactFlags.new(
        { guardian_no_email_address: '1', no_phone_number: '1' },
        scope: :guardian
      )

      normalized = guardian_flags.apply_to(
        email: 'guardian@example.com',
        phone: '410-555-0102',
        phone_type: 'voice',
        communication_preference: 'email'
      )

      assert_nil normalized[:email]
      assert_equal '410-555-0102', normalized[:phone]
      assert_equal 'voice', normalized[:phone_type]
      assert_equal 'letter', normalized[:communication_preference]
      assert guardian_flags.skip_email_validation?
      assert_not guardian_flags.skip_phone_validation?
    end

    test 'clear flags set nil values for persisted contact updates' do
      flags = PaperContactFlags.new(
        { no_email_address: '1', no_phone_number: '1' },
        scope: :constituent
      )

      updates = flags.apply_clear_flags_to(email: 'ignored@example.com', phone: '410-555-0103')

      assert_nil updates[:email]
      assert_nil updates[:phone]
      assert_equal 'letter', updates[:phone_type]
      assert_equal 'letter', updates[:communication_preference]
    end
  end
end
