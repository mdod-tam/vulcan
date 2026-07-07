# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class MetadataSanitizerTest < ActiveSupport::TestCase
    test 'build drops raw contact fields from subject snapshot' do
      digest = 'a' * 64

      metadata = MetadataSanitizer.build(
        reason_codes: ['name_dob'],
        intake_context: 'registration',
        subject_snapshot: {
          contact_digest: digest,
          email: 'secret@example.com',
          phone: '410-555-0100'
        }
      )

      assert_equal digest, metadata[:subject_snapshot]['contact_digest']
      assert_not metadata[:subject_snapshot].key?('email')
      assert_not metadata[:subject_snapshot].key?('phone')
    end

    test 'build rejects invalid intake context' do
      metadata = MetadataSanitizer.build(
        reason_codes: ['name_dob'],
        intake_context: 'public_registration_blocked'
      )

      assert_not metadata.key?(:intake_context)
    end

    test 'duplicate review case rejects raw subject snapshot keys at validation' do
      subject = create(:constituent)
      duplicate_case = DuplicateReviewCase.new(
        source: :registration_soft_match,
        subject_user: subject,
        deduplication_key: SecureRandom.hex(32),
        opened_at: Time.current,
        metadata: {
          reason_codes: ['name_dob'],
          subject_snapshot: { email: 'secret@example.com' }
        }
      )

      assert_not duplicate_case.valid?
      assert_includes duplicate_case.errors[:metadata].join(' '), 'subject_snapshot'
    end
  end
end
