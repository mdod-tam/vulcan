# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class CandidateSnapshotSanitizerTest < ActiveSupport::TestCase
    test 'sanitize drops raw contact values under allowed keys' do
      sanitized = CandidateSnapshotSanitizer.sanitize(
        contact_digest: 'secret@example.com',
        last_four: '4105550198',
        real_email: true,
        email: 'also-secret@example.com'
      )

      assert_not sanitized.key?('contact_digest')
      assert_not sanitized.key?('last_four')
      assert_equal true, sanitized['real_email']
      assert_not sanitized.key?('email')
    end

    test 'sanitize keeps valid digest and last four values' do
      digest = 'd' * 64

      sanitized = CandidateSnapshotSanitizer.sanitize(
        contact_digest: digest,
        last_four: '0198',
        real_phone: false
      )

      assert_equal digest, sanitized['contact_digest']
      assert_equal '0198', sanitized['last_four']
      assert_equal false, sanitized['real_phone']
    end

    test 'invalid_snapshot_values detects raw contact under allowed keys' do
      assert CandidateSnapshotSanitizer.invalid_snapshot_values?(
        contact_digest: 'secret@example.com',
        last_four: '4105550198'
      )
    end

    test 'duplicate review case candidate rejects raw snapshot values at validation' do
      duplicate_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: create(:constituent),
        deduplication_key: SecureRandom.hex(32),
        opened_at: Time.current,
        metadata: { reason_codes: ['name_dob'], intake_context: 'registration' }
      )

      candidate = duplicate_case.duplicate_review_case_candidates.build(
        candidate_user: create(:constituent),
        match_reason: 'name_dob',
        snapshot: { contact_digest: 'secret@example.com' }
      )

      assert_not candidate.valid?
      assert_includes candidate.errors[:snapshot].join(' '), 'raw contact values'
    end
  end
end
