# frozen_string_literal: true

require 'test_helper'
require 'rake'

module DuplicateReconciliation
  class DiscoveryProbeTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    setup do
      DatabaseCleaner.clean
      @initial_user_ids = User.pluck(:id)
      @probe = DiscoveryProbe.new(statement_timeout_ms: 5000, sample_limit: 3)
    end

    teardown do
      cleanup_test_records!
    end

    test 'production transaction path enforces repeatable read isolation and rejects writes' do
      probe = DiscoveryProbe.new(statement_timeout_ms: 5000)
      result = probe.call

      assert_equal 'repeatable read', result.provenance[:transaction_isolation]
      assert_equal 'on', result.provenance[:transaction_read_only]

      err = assert_raises ActiveRecord::StatementInvalid do
        probe.with_read_only_transaction do
          ActiveRecord::Base.connection.execute(
            'INSERT INTO users (type, first_name, last_name, password_digest, force_password_change, needs_duplicate_review, created_at, updated_at) ' \
            "VALUES ('Users::Constituent', 'Test', 'Write', 'valid_digest', false, false, NOW(), NOW())"
          )
        end
      end
      assert_match(/cannot execute INSERT in a read-only transaction/i, err.message)
      assert_instance_of PG::ReadOnlySqlTransaction, err.cause if err.cause
    end

    test 'production transaction path enforces remaining statement timeout cancelling slow query' do
      probe = DiscoveryProbe.new(statement_timeout_ms: 250)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      err = assert_raises ActiveRecord::StatementInvalid do
        probe.with_read_only_transaction do
          probe.query_with_timeout do
            ActiveRecord::Base.connection.execute('SELECT pg_sleep(2)')
          end
        end
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      assert_match(/canceling statement due to statement timeout/i, err.message)
      assert elapsed < 1.0, "Expected query to be canceled within ~250ms, took #{elapsed}s"
      assert elapsed >= 0.2, "Expected query to run for at least 200ms before timeout, took #{elapsed}s"
    end

    test 'rejects execution inside an existing open transaction' do
      ActiveRecord::Base.transaction do
        err = assert_raises RuntimeError do
          @probe.call
        end
        assert_match(/must not be executed inside an existing open transaction/i, err.message)
      end
    end

    test 'rake duplicates:discovery invokes probe in non-transactional production path' do
      Rails.application.load_tasks unless Rake::Task.task_defined?('duplicates:discovery')
      Rake::Task['duplicates:discovery'].reenable

      out, _err = capture_io do
        Rake::Task['duplicates:discovery'].invoke
      end

      assert_includes out, '=== PR 208 ARCHITECTURE DISCOVERY PROBE ==='
      assert_includes out, 'Transaction:  isolation=repeatable read, read_only=on'
      assert_includes out, 'PII Redacted: true'
    end

    test 'rake duplicates:discovery rejects invalid DETAILED_PII values' do
      Rails.application.load_tasks unless Rake::Task.task_defined?('duplicates:discovery')

      %w[typo tru yes on 1 TRUE].push(' true ').each do |bad_val|
        Rake::Task['duplicates:discovery'].reenable
        err = assert_raises SystemExit do
          ENV['DETAILED_PII'] = bad_val
          capture_io { Rake::Task['duplicates:discovery'].invoke }
        end
        assert_equal 1, err.status
      ensure
        ENV.delete('DETAILED_PII')
      end
    end

    test 'rake duplicates:discovery enables detailed PII only with exact allowlisted value true' do
      Rails.application.load_tasks unless Rake::Task.task_defined?('duplicates:discovery')
      Rake::Task['duplicates:discovery'].reenable

      begin
        ENV['DETAILED_PII'] = 'true'
        out, _err = capture_io do
          Rake::Task['duplicates:discovery'].invoke
        end
        assert_includes out, 'PII Redacted: false'
        assert_includes out, 'NOTE: SENSITIVE PII INCLUDED'
      ensure
        ENV.delete('DETAILED_PII')
      end
    end

    test 'derives opaque cluster reference from cluster key rather than cluster size' do
      ref_a = @probe.send(:opaque_ref, 'cluster', 'alpha:person:dob1')
      ref_b = @probe.send(:opaque_ref, 'cluster', 'beta:other:dob2')
      assert_not_equal ref_a, ref_b

      dob1 = Date.new(1982, 3, 4)
      u1 = create(:user, type: 'Users::Constituent', first_name: 'ClusterA', last_name: 'Alpha', date_of_birth: dob1, status: :active)
      u2 = create(:user, type: 'Users::Constituent', first_name: 'ClusterA', last_name: 'Alpha', date_of_birth: dob1, status: :active)

      dob2 = Date.new(1984, 7, 8)
      create(:user, type: 'Users::Constituent', first_name: 'ClusterB', last_name: 'Beta', date_of_birth: dob2, status: :active)
      create(:user, type: 'Users::Constituent', first_name: 'ClusterB', last_name: 'Beta', date_of_birth: dob2, status: :active)

      result1 = @probe.call
      sample1 = result1.samples[:largest_matching_group]
      assert_not_nil sample1
      assert_equal 2, sample1[:size]

      [u1, u2].each { |u| u.update_column(:status, 0) }

      result2 = @probe.call
      sample2 = result2.samples[:largest_matching_group]
      assert_not_nil sample2
      assert_equal 2, sample2[:size]
      assert_not_equal sample1[:cluster_ref], sample2[:cluster_ref],
                       'Equal-sized clusters must have distinct cluster_refs derived from cluster key'

      rendered = @probe.render_summary(result2)
      assert_includes rendered, "[cluster_ref: #{sample2[:cluster_ref]}]"
    end

    test 'runs safely and returns structured Result without any database mutation' do
      assert_no_difference ['DuplicateReviewCase.count', 'User.count', 'GuardianRelationship.count'] do
        result = @probe.call(detailed_pii: false)
        assert_instance_of DiscoveryProbe::Result, result
        assert_equal Rails.env, result.provenance[:rails_env]
        assert result.provenance[:database_fingerprint].present?
        assert result.case_metrics.key?(:total_cases)
        assert result.flag_metrics.key?(:total_flagged_constituents)
        assert result.matching_metrics.key?(:cluster_count)
        assert result.guardian_metrics.key?(:total_relationships)
      end
    end

    test 'redacts PII from default output and samples for multi-guardian dependents' do
      dependent = create(:user, type: 'Users::Constituent', first_name: 'SecretChild', last_name: 'PrivateName')
      g1 = create(:user, type: 'Users::Constituent', first_name: 'SecretGuardianOne', last_name: 'PrivateName')
      g2 = create(:user, type: 'Users::Constituent', first_name: 'SecretGuardianTwo', last_name: 'PrivateName')
      create(:guardian_relationship, dependent_user: dependent, guardian_user: g1)
      create(:guardian_relationship, dependent_user: dependent, guardian_user: g2)

      # 1. Default mode: detailed_pii: false
      default_result = @probe.call(detailed_pii: false)
      sample = default_result.samples[:multi_guardian_dependents].first
      assert_not_nil sample
      assert_nil sample[:dependent_name]
      assert_nil sample[:dependent_id]

      rendered_default = @probe.render_summary(default_result, detailed_pii: false)
      assert_includes rendered_default, 'PII Redacted: true'
      assert_not_includes rendered_default, 'SecretChild'
      assert_not_includes rendered_default, 'SecretGuardianOne'
      assert_not_includes rendered_default, 'SecretGuardianTwo'
      assert_not_includes rendered_default, 'localhost'

      # 2. Detailed mode: detailed_pii: true
      detailed_result = @probe.call(detailed_pii: true)
      detailed_sample = detailed_result.samples[:multi_guardian_dependents].first
      assert_not_nil detailed_sample
      assert_equal "#{dependent.first_name} #{dependent.last_name}", detailed_sample[:dependent_name]
      assert_equal dependent.id, detailed_sample[:dependent_id]

      guardian_names = detailed_sample[:relationships].pluck(:guardian_name)
      assert_includes guardian_names, "#{g1.first_name} #{g1.last_name}"
      assert_includes guardian_names, "#{g2.first_name} #{g2.last_name}"

      rendered_detailed = @probe.render_summary(detailed_result, detailed_pii: true)
      assert_includes rendered_detailed, 'PII Redacted: false'
      assert_includes rendered_detailed, 'SENSITIVE PII INCLUDED'
      assert_includes rendered_detailed, 'SecretChild'
      assert_includes rendered_detailed, 'SecretGuardianOne'
      assert_includes rendered_detailed, 'SecretGuardianTwo'
    end

    test 'caps detailed guardian relationships per dependent and reports omitted count' do
      probe = DiscoveryProbe.new(statement_timeout_ms: 5000, sample_limit: 2)
      dependent = create(:user, type: 'Users::Constituent', first_name: 'ManyGuardians', last_name: 'Child')
      5.times do |i|
        g = create(:user, type: 'Users::Constituent', first_name: "Guardian#{i}", last_name: 'Child')
        create(:guardian_relationship, dependent_user: dependent, guardian_user: g)
      end

      detailed_result = probe.call(detailed_pii: true)
      sample = detailed_result.samples[:multi_guardian_dependents].find { |s| s[:dependent_id] == dependent.id }
      assert_not_nil sample
      assert_equal 5, sample[:guardian_count]
      assert_equal 5, sample[:relationship_count]
      assert_equal 2, sample[:relationships].size
      assert_equal 3, sample[:omitted_relationships_count]

      rendered = probe.render_summary(detailed_result, detailed_pii: true)
      assert_includes rendered, 'and 3 more relationship(s) omitted'
    end

    test 'detects malformed post-import cases and tracks their participants in flag metrics' do
      c1 = create(:user, type: 'Users::Constituent', first_name: 'John', last_name: 'Doe', date_of_birth: Date.new(1990, 1, 1))
      c2 = create(:user, type: 'Users::Constituent', first_name: 'John', last_name: 'Doe', date_of_birth: Date.new(1990, 1, 1))
      c3 = create(:user, type: 'Users::Constituent', first_name: 'John', last_name: 'Doe', date_of_birth: Date.new(1990, 1, 1))

      malformed_case = DuplicateReviewCase.create!(
        source: :post_import_reconciliation,
        subject_user: c1,
        status: :open,
        opened_at: Time.current,
        deduplication_key: "test_malformed_#{SecureRandom.hex(8)}",
        metadata: { 'reason_codes' => ['name_dob'] }
      )
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: malformed_case, candidate_user: c2, match_reason: 'name_dob')
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: malformed_case, candidate_user: c3, match_reason: 'name_dob')

      result = @probe.call(detailed_pii: true)
      assert_equal 1, result.case_metrics[:post_import_malformed]
      assert_includes result.samples[:malformed_cases].map { |c| c.fetch(:id) }, malformed_case.id

      assert_equal 3, result.flag_metrics[:malformed_open_case_participants]
    end

    test 'captures malformed post-import case when metadata lacks reason_codes (SQL NULL handling)' do
      c1 = create(:user, type: 'Users::Constituent', first_name: 'Null', last_name: 'Reason', date_of_birth: Date.new(1991, 2, 3))
      c2 = create(:user, type: 'Users::Constituent', first_name: 'Null', last_name: 'Reason', date_of_birth: Date.new(1991, 2, 3))

      u1, u2 = [c1, c2].sort_by(&:id)

      null_meta_case = DuplicateReviewCase.create!(
        source: :post_import_reconciliation,
        subject_user: u1,
        status: :open,
        opened_at: Time.current,
        deduplication_key: "test_null_meta_#{SecureRandom.hex(8)}",
        metadata: { 'reason_codes' => ['name_dob'] }
      )
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: null_meta_case, candidate_user: u2, match_reason: 'name_dob')

      null_meta_case.update_column(:metadata, {})

      result = @probe.call(detailed_pii: true)
      assert_equal 1, result.case_metrics[:post_import_malformed]
      assert_includes result.samples[:malformed_cases].map { |c| c.fetch(:id) }, null_meta_case.id
      assert_equal 2, result.flag_metrics[:malformed_open_case_participants]
    end

    test 'reports total multi-case pairs accurately beyond sample_limit' do
      probe = DiscoveryProbe.new(statement_timeout_ms: 5000, sample_limit: 2)
      4.times do |i|
        u1 = create(:user, type: 'Users::Constituent', first_name: "PairUserA#{i}", last_name: 'Multi', date_of_birth: Date.new(1980 + i, 1, 1))
        u2 = create(:user, type: 'Users::Constituent', first_name: "PairUserB#{i}", last_name: 'Multi', date_of_birth: Date.new(1980 + i, 1, 1))
        first, second = [u1, u2].sort_by(&:id)

        2.times do |j|
          c = DuplicateReviewCase.create!(
            source: :post_import_reconciliation,
            subject_user: first,
            status: :open,
            opened_at: Time.current,
            deduplication_key: "multi_pair_#{i}_#{j}_#{SecureRandom.hex(6)}",
            metadata: { 'reason_codes' => ['name_dob'] }
          )
          DuplicateReviewCaseCandidate.create!(duplicate_review_case: c, candidate_user: second, match_reason: 'name_dob')
        end
      end

      result = probe.call
      assert_equal 4, result.case_metrics[:pairs_with_multiple_cases]
      assert_equal 2, result.samples[:multi_case_pairs].size
    end

    test 'measures flag drift correctly distinguishing dynamic matches from true drift' do
      dob = Date.new(1980, 5, 10)
      _m1 = create(:user, type: 'Users::Constituent', first_name: 'MatchA', last_name: 'Person', date_of_birth: dob, needs_duplicate_review: true, status: :active)
      _m2 = create(:user, type: 'Users::Constituent', first_name: 'MatchA', last_name: 'Person', date_of_birth: dob, needs_duplicate_review: true, status: :active)

      drift_user = create(:user, type: 'Users::Constituent', first_name: 'Solo', last_name: 'Unique', date_of_birth: Date.new(1975, 3, 15), needs_duplicate_review: true, status: :active)

      result = @probe.call(detailed_pii: true)
      assert_equal 1, result.flag_metrics[:flagged_without_open_case_or_match]
      assert_equal drift_user.id, result.samples[:flag_discrepancies].first[:id]
      assert_equal 3, result.flag_metrics[:flagged_without_open_case]
    end

    test 'default structured results redact raw identifiers at the result-producing boundary' do
      c1 = create(:user, type: 'Users::Constituent', first_name: 'Boundary', last_name: 'Case', date_of_birth: Date.new(1990, 1, 1))
      c2 = create(:user, type: 'Users::Constituent', first_name: 'Boundary', last_name: 'Case', date_of_birth: Date.new(1990, 1, 1))
      c3 = create(:user, type: 'Users::Constituent', first_name: 'Boundary', last_name: 'Case', date_of_birth: Date.new(1990, 1, 1))

      malformed_case = DuplicateReviewCase.create!(
        source: :post_import_reconciliation,
        subject_user: c1,
        status: :open,
        opened_at: Time.current,
        deduplication_key: "boundary_malformed_#{SecureRandom.hex(8)}",
        metadata: { 'reason_codes' => ['name_dob'] }
      )
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: malformed_case, candidate_user: c2, match_reason: 'name_dob')
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: malformed_case, candidate_user: c3, match_reason: 'name_dob')

      drift_user = create(:user, type: 'Users::Constituent', first_name: 'Drift', last_name: 'Redact', needs_duplicate_review: true)

      default_res = @probe.call(detailed_pii: false)

      malformed_sample = default_res.samples[:malformed_cases].first
      assert_not_nil malformed_sample
      assert_nil malformed_sample[:id]
      assert_nil malformed_sample[:subject_user_id]
      assert_nil malformed_sample[:reason_codes]
      assert malformed_sample[:ref].present?

      drift_sample = default_res.samples[:flag_discrepancies].first
      assert_not_nil drift_sample
      assert_nil drift_sample[:id]
      assert drift_sample[:ref].present?

      detailed_res = @probe.call(detailed_pii: true)
      detailed_malformed = detailed_res.samples[:malformed_cases].first
      assert_equal malformed_case.id, detailed_malformed[:id]
      assert_equal c1.id, detailed_malformed[:subject_user_id]
      assert_not_nil detailed_malformed[:reason_codes]

      detailed_drift = detailed_res.samples[:flag_discrepancies].find { |s| s[:id] == drift_user.id }
      assert_not_nil detailed_drift
      assert_equal drift_user.id, detailed_drift[:id]
    end

    test 'measures flag drift correctly distinguishing canonical strict post-import keep_separate from non-post-import or malformed cases' do
      admin = create(:admin)
      dob = Date.new(1983, 6, 15)

      # 1. Non-post-import case (registration_soft_match) with keep_separate:
      # Canonical Population does NOT recognize this as a post-import pair resolution.
      # The dynamic match remains active, flags are required under ReviewFlagProjection, so drift = 0.
      r1 = create(:constituent, first_name: 'Reg', last_name: 'Match', date_of_birth: dob, needs_duplicate_review: true, status: :active)
      r2 = create(:constituent, first_name: 'Reg', last_name: 'Match', date_of_birth: dob, needs_duplicate_review: true, status: :active)
      r_first, r_second = [r1, r2].sort_by(&:id)

      reg_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: r_first,
        status: :open,
        opened_at: 1.day.ago,
        deduplication_key: "reg_sep_#{SecureRandom.hex(8)}",
        metadata: { 'reason_codes' => ['name_dob'] }
      )
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: reg_case, candidate_user: r_second, match_reason: 'name_dob')
      reg_case.update!(
        status: :resolved_ignored,
        resolution_determination: 'keep_separate',
        resolution_rationale: 'Confirmed different in registration review',
        resolved_at: Time.current,
        resolved_by: admin
      )

      assert DuplicateReconciliation::ReviewFlagProjection.new.required_for?(r1)
      assert DuplicateReconciliation::ReviewFlagProjection.new.required_for?(r2)

      # 2. Malformed post-import case (inverted orientation: subject > candidate) with keep_separate:
      # Canonical Population rejects malformed post-import cases; dynamic match remains active, drift = 0.
      m1 = create(:constituent, first_name: 'Mal', last_name: 'Shape', date_of_birth: dob, needs_duplicate_review: true, status: :active)
      m2 = create(:constituent, first_name: 'Mal', last_name: 'Shape', date_of_birth: dob, needs_duplicate_review: true, status: :active)
      m_first, m_second = [m1, m2].sort_by(&:id)

      mal_case = DuplicateReviewCase.create!(
        source: :post_import_reconciliation,
        subject_user: m_second,
        status: :open,
        opened_at: 1.day.ago,
        deduplication_key: "mal_sep_#{SecureRandom.hex(8)}",
        metadata: { 'reason_codes' => ['name_dob'] }
      )
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: mal_case, candidate_user: m_first, match_reason: 'name_dob')
      mal_case.update!(
        status: :resolved_ignored,
        resolution_determination: 'keep_separate',
        resolution_rationale: 'Confirmed different',
        resolved_at: Time.current,
        resolved_by: admin
      )

      assert DuplicateReconciliation::ReviewFlagProjection.new.required_for?(m1)
      assert DuplicateReconciliation::ReviewFlagProjection.new.required_for?(m2)

      res_before = @probe.call
      assert_equal 0, res_before.flag_metrics[:flagged_without_open_case_or_match]

      # 3. Canonical strict post-import case:
      # Canonical Population classifies as confirmed_different; dynamic match is resolved; flags ARE true drift = 2!
      s1 = create(:constituent, first_name: 'Strict', last_name: 'Match', date_of_birth: dob, needs_duplicate_review: true, status: :active)
      s2 = create(:constituent, first_name: 'Strict', last_name: 'Match', date_of_birth: dob, needs_duplicate_review: true, status: :active)
      s_first, s_second = [s1, s2].sort_by(&:id)

      strict_case = DuplicateReviewCase.create!(
        source: :post_import_reconciliation,
        subject_user: s_first,
        status: :open,
        opened_at: 1.day.ago,
        deduplication_key: "strict_sep_#{SecureRandom.hex(8)}",
        metadata: { 'reason_codes' => ['name_dob'] }
      )
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: strict_case, candidate_user: s_second, match_reason: 'name_dob')
      strict_case.update!(
        status: :resolved_ignored,
        resolution_determination: 'keep_separate',
        resolution_rationale: 'Confirmed different via photo ID',
        resolved_at: Time.current,
        resolved_by: admin
      )

      assert_not DuplicateReconciliation::ReviewFlagProjection.new.required_for?(s1)
      assert_not DuplicateReconciliation::ReviewFlagProjection.new.required_for?(s2)

      res_after = @probe.call
      assert_equal 2, res_after.flag_metrics[:flagged_without_open_case_or_match]
    end

    test 'dynamic matching and drift metrics handle JSON-shaped undecryptable ciphertext' do
      initial_cluster_count = @probe.call.matching_metrics[:cluster_count]
      initial_dynamic_pairs = @probe.call.matching_metrics[:total_dynamic_pairs]

      u1 = create(:constituent, first_name: 'Undecrypt', last_name: 'JsonDob', needs_duplicate_review: true, status: :active)
      u2 = create(:constituent, first_name: 'Undecrypt', last_name: 'JsonDob', needs_duplicate_review: true, status: :active)

      bad_json_dob = '{"p":"corrupt_payload_abc123","h":{"iv":"123","at":"456"}}'
      Users::Constituent.where(id: [u1.id, u2.id]).update_all(date_of_birth: bad_json_dob)

      u1.reload
      u2.reload
      assert_nil u1.date_of_birth
      assert_nil u2.date_of_birth
      assert_not DuplicateReconciliation::ReviewFlagProjection.new.required_for?(u1)
      assert_not DuplicateReconciliation::ReviewFlagProjection.new.required_for?(u2)

      res = @probe.call

      assert_equal initial_cluster_count, res.matching_metrics[:cluster_count]
      assert_equal initial_dynamic_pairs, res.matching_metrics[:total_dynamic_pairs]
      assert_equal 1, res.matching_metrics[:invalid_dob_clusters]

      assert_equal 2, res.flag_metrics[:flagged_without_open_case_or_match]
    end

    test 'dynamic matching and drift metrics support legacy plaintext DOBs' do
      initial_cluster_count = @probe.call.matching_metrics[:cluster_count]
      initial_dynamic_pairs = @probe.call.matching_metrics[:total_dynamic_pairs]

      u1 = create(:constituent, first_name: 'Plaintext', last_name: 'LegacyDob', needs_duplicate_review: true, status: :active)
      u2 = create(:constituent, first_name: 'Plaintext', last_name: 'LegacyDob', needs_duplicate_review: true, status: :active)

      Users::Constituent.where(id: [u1.id, u2.id]).update_all(date_of_birth: '1985-04-12')

      u1.reload
      u2.reload
      assert_equal Date.new(1985, 4, 12), u1.date_of_birth
      assert_equal Date.new(1985, 4, 12), u2.date_of_birth
      assert DuplicateReconciliation::ReviewFlagProjection.new.required_for?(u1)
      assert DuplicateReconciliation::ReviewFlagProjection.new.required_for?(u2)

      res = @probe.call

      assert_equal initial_cluster_count + 1, res.matching_metrics[:cluster_count]
      assert_equal initial_dynamic_pairs + 1, res.matching_metrics[:total_dynamic_pairs]

      assert_equal 0, res.flag_metrics[:flagged_without_open_case_or_match]
    end

    test 'matching metrics maintain bounded behavior with many clusters' do
      4.times do |i|
        create(:constituent, first_name: "MultiCluster#{i}", last_name: 'Person', date_of_birth: Date.new(1980 + i, 1, 1), status: :active)
        create(:constituent, first_name: "MultiCluster#{i}", last_name: 'Person', date_of_birth: Date.new(1980 + i, 1, 1), status: :active)
      end

      bounded_probe = DuplicateReconciliation::DiscoveryProbe.new(cluster_limit: 2)
      res = bounded_probe.call

      assert res.matching_metrics[:dob_audit_truncated]
      assert_equal 2, res.matching_metrics[:audited_clusters]
      assert_nil res.matching_metrics[:cluster_count]
      assert_nil res.matching_metrics[:total_dynamic_pairs]
      assert res.matching_metrics[:raw_cluster_count] >= 4
    end

    test 'measures flag drift as lower bound and reports truncation when corrupt candidates exceed audit limit' do
      v1 = create(:constituent, first_name: 'AlphaValid', last_name: 'Drift', date_of_birth: Date.new(1982, 3, 4), needs_duplicate_review: true, status: :active)
      v2 = create(:constituent, first_name: 'AlphaValid', last_name: 'Drift', date_of_birth: Date.new(1982, 3, 4), needs_duplicate_review: true, status: :active)
      c1 = create(:constituent, first_name: 'BetaCorrupt', last_name: 'Drift', needs_duplicate_review: true, status: :active)
      c2 = create(:constituent, first_name: 'BetaCorrupt', last_name: 'Drift', needs_duplicate_review: true, status: :active)

      bad_json_dob = '{"p":"corrupt_drift_123","h":{"iv":"1","at":"2"}}'
      Users::Constituent.where(id: [c1.id, c2.id]).update_all(date_of_birth: bad_json_dob)

      assert v1.id < c1.id && v2.id < c2.id
      assert_not DuplicateReconciliation::ReviewFlagProjection.new.required_for?(c1.reload)
      assert_not DuplicateReconciliation::ReviewFlagProjection.new.required_for?(c2.reload)

      bounded_probe = DuplicateReconciliation::DiscoveryProbe.new(cluster_limit: 1)
      res = bounded_probe.call

      assert res.flag_metrics[:drift_dob_audit_truncated]
      assert_equal 1, res.flag_metrics[:audited_drift_candidates]
      assert res.flag_metrics[:total_drift_candidates] >= 4
      assert_equal 0, res.flag_metrics[:flagged_without_open_case_or_match]

      rendered = bounded_probe.render_summary(res)
      assert_includes rendered, 'Flagged but NO open case and NO dynamic match:  >= 0 (true flag drift, lower bound; audit truncated)'
      assert_includes rendered, "NOTE: Drift candidate DOB audit was bounded to 1 of #{res.flag_metrics[:total_drift_candidates]} candidates; " \
                                'additional corrupt matches may exist'
    end

    test 'truncated cluster audit containing invalid cluster reports raw totals and uncertain wording without claiming exclusions' do
      create(:constituent, first_name: 'AaaBad', last_name: 'AuditCluster', needs_duplicate_review: false, status: :active)
      create(:constituent, first_name: 'AaaBad', last_name: 'AuditCluster', needs_duplicate_review: false, status: :active)
      Users::Constituent.where(first_name: 'AaaBad').update_all(date_of_birth: '{"p":"bad_cluster_payload","h":{"iv":"1","at":"2"}}')

      create(:constituent, first_name: 'BbbGood', last_name: 'AuditCluster', date_of_birth: Date.new(1980, 2, 2), status: :active)
      create(:constituent, first_name: 'BbbGood', last_name: 'AuditCluster', date_of_birth: Date.new(1980, 2, 2), status: :active)

      create(:constituent, first_name: 'CccGood', last_name: 'AuditCluster', date_of_birth: Date.new(1981, 3, 3), status: :active)
      create(:constituent, first_name: 'CccGood', last_name: 'AuditCluster', date_of_birth: Date.new(1981, 3, 3), status: :active)

      bounded_probe = DuplicateReconciliation::DiscoveryProbe.new(cluster_limit: 2)
      res = bounded_probe.call

      assert res.matching_metrics[:dob_audit_truncated]
      assert_equal 2, res.matching_metrics[:audited_clusters]
      assert res.matching_metrics[:raw_cluster_count] >= 3
      assert res.matching_metrics[:invalid_dob_clusters] >= 1
      assert_nil res.matching_metrics[:cluster_count]
      assert_nil res.matching_metrics[:total_dynamic_pairs]
      assert_nil res.matching_metrics[:cluster_size_distribution]

      rendered = bounded_probe.render_summary(res)
      assert_includes rendered, "Raw SQL Name + DOB clusters:  #{res.matching_metrics[:raw_cluster_count]} (unverified; cluster audit truncated)"
      assert_includes rendered, "NOTE: Cluster DOB audit was bounded to 2 of #{res.matching_metrics[:raw_cluster_count]} clusters; canonical totals not verified"
      assert_includes rendered, 'Invalid/undecryptable DOB clusters in sample: 1 of 2 audited (canonical exclusion incomplete)'
      assert_no_match(/excluded from verified dynamic matching/, rendered)
      assert_no_match(/excluded from dynamic matching/, rendered)
    end

    test 'dob validation and user date_of_birth never write raw DOB values to application logs' do
      log_output = StringIO.new
      test_logger = Logger.new(log_output)
      original_logger = Rails.logger
      Rails.logger = test_logger
      begin
        @probe.send(:valid_dob?, '1985-99-99')
        @probe.send(:valid_dob?, '{"p":"super_secret_corrupt_payload","h":{"iv":"1","at":"2"}}')
        @probe.send(:valid_dob?, 'not-a-date')

        u = Users::Constituent.instantiate('id' => 999_888, 'date_of_birth' => '1985-99-99')
        u.date_of_birth

        u2 = Users::Constituent.instantiate('id' => 999_889, 'date_of_birth' => '{"p":"another_secret_payload","h":{"iv":"1","at":"2"}}')
        u2.date_of_birth

        log_str = log_output.string
        assert_no_match(/1985-99-99/, log_str)
        assert_no_match(/super_secret_corrupt_payload/, log_str)
        assert_no_match(/another_secret_payload/, log_str)
        assert_includes log_str, 'Invalid date format for user 999888'
      ensure
        Rails.logger = original_logger
      end
    end

    test 'renders duplicate-pair case samples in summary output' do
      u1 = create(:user, type: 'Users::Constituent', first_name: 'Sample', last_name: 'MultiPair', date_of_birth: Date.new(1988, 8, 8))
      u2 = create(:user, type: 'Users::Constituent', first_name: 'Sample', last_name: 'MultiPair', date_of_birth: Date.new(1988, 8, 8))
      first, second = [u1, u2].sort_by(&:id)

      2.times do |j|
        c = DuplicateReviewCase.create!(
          source: :post_import_reconciliation,
          subject_user: first,
          status: :open,
          opened_at: Time.current,
          deduplication_key: "render_multi_pair_#{j}_#{SecureRandom.hex(6)}",
          metadata: { 'reason_codes' => ['name_dob'] }
        )
        DuplicateReviewCaseCandidate.create!(duplicate_review_case: c, candidate_user: second, match_reason: 'name_dob')
      end

      res_default = @probe.call(detailed_pii: false)
      rendered_default = @probe.render_summary(res_default, detailed_pii: false)
      assert_includes rendered_default, 'Sample duplicate-pair cases (1):'
      assert_includes rendered_default, 'Pair ref '
      assert_includes rendered_default, '2 cases'

      res_detailed = @probe.call(detailed_pii: true)
      rendered_detailed = @probe.render_summary(res_detailed, detailed_pii: true)
      assert_includes rendered_detailed, 'Sample duplicate-pair cases (1):'
      assert_includes rendered_detailed, "Pair #{first.id}-#{second.id}: 2 cases"
    end

    test 'measures flag drift correctly including inactive and merged flagged users without dynamic matches' do
      dob = Date.new(1980, 5, 10)
      create(:user, type: 'Users::Constituent', first_name: 'Shared', last_name: 'Person', date_of_birth: dob, status: :active)

      inactive_user = create(
        :user,
        type: 'Users::Constituent',
        first_name: 'Shared',
        last_name: 'Person',
        date_of_birth: dob,
        status: :inactive,
        needs_duplicate_review: true
      )

      canonical_user = create(:user, type: 'Users::Constituent', first_name: 'Merged', last_name: 'Person', date_of_birth: dob, status: :active)
      merged_user = create(
        :user,
        type: 'Users::Constituent',
        first_name: 'Shared',
        last_name: 'Person',
        date_of_birth: dob,
        status: :active,
        merged_into_user_id: canonical_user.id,
        needs_duplicate_review: true
      )

      result = @probe.call(detailed_pii: true)
      drift_sample_ids = result.samples[:flag_discrepancies].pluck(:id)
      assert_includes drift_sample_ids, inactive_user.id
      assert_includes drift_sample_ids, merged_user.id
      assert result.flag_metrics[:flagged_without_open_case_or_match] >= 2
    end

    test 'correctly counts non-post-import candidate participants' do
      subject_user = create(:user, type: 'Users::Constituent', needs_duplicate_review: true)
      candidate_user = create(:user, type: 'Users::Constituent', needs_duplicate_review: false)

      reg_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: subject_user,
        status: :open,
        opened_at: Time.current,
        deduplication_key: "test_reg_#{SecureRandom.hex(8)}",
        metadata: { 'reason_codes' => ['name_dob'] }
      )
      DuplicateReviewCaseCandidate.create!(duplicate_review_case: reg_case, candidate_user: candidate_user, match_reason: 'name_dob')

      result = @probe.call
      assert result.flag_metrics[:open_case_constituents_unflagged] >= 1
    end

    test 'handles legacy NULL user status as active constituents in dynamic matching' do
      create(:user, type: 'Users::Constituent', first_name: 'Legacy', last_name: 'User', date_of_birth: Date.new(1985, 5, 20), status: nil)
      create(:user, type: 'Users::Constituent', first_name: 'Legacy', last_name: 'User', date_of_birth: Date.new(1985, 5, 20), status: nil)

      result = @probe.call
      assert result.matching_metrics[:cluster_count] >= 1
      assert result.matching_metrics[:total_dynamic_pairs] >= 1
    end

    test 'bounds sample collections to sample_limit' do
      5.times do |i|
        dep = create(:user, type: 'Users::Constituent', first_name: "Child#{i}", last_name: 'Test')
        2.times do |j|
          g = create(:user, type: 'Users::Constituent', first_name: "Guardian#{i}_#{j}", last_name: 'Test')
          create(:guardian_relationship, dependent_user: dep, guardian_user: g)
        end
      end

      result = @probe.call
      assert_equal 3, result.samples[:multi_guardian_dependents].size
    end

    test 'uses keyed HMAC salt for opaque references and generates stable database fingerprint across instances' do
      probe1 = DiscoveryProbe.new(statement_timeout_ms: 5000)
      probe2 = DiscoveryProbe.new(statement_timeout_ms: 5000)

      ref1 = probe1.send(:opaque_ref, 'user', 42)
      ref2 = probe2.send(:opaque_ref, 'user', 42)

      assert_equal 8, ref1.length
      assert_equal 8, ref2.length
      assert_not_equal ref1, ref2
      assert_not_equal Digest::SHA256.hexdigest('user_42')[0..7], ref1

      # Database fingerprint is stable across instances using application-secret HMAC
      fp1 = probe1.send(:collect_provenance)[:database_fingerprint]
      fp2 = probe2.send(:collect_provenance)[:database_fingerprint]
      assert_equal fp1, fp2
      assert_equal 8, fp1.length
    end

    test 'enforces total deadline raising Timeout::Error if budget is exhausted' do
      probe = DiscoveryProbe.new(statement_timeout_ms: 10)
      probe.instance_variable_set(:@deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1.0)

      assert_raises Timeout::Error do
        probe.send(:apply_remaining_timeout!)
      end
    end

    private

    def cleanup_test_records!
      new_user_ids = User.where.not(id: @initial_user_ids).pluck(:id)
      return if new_user_ids.empty?

      case_ids = DuplicateReviewCase.where('subject_user_id IN (?) OR resolved_by_id IN (?)', new_user_ids, new_user_ids).pluck(:id)
      DuplicateReviewCaseCandidate.where(duplicate_review_case_id: case_ids).delete_all
      DuplicateReviewCaseCandidate.where(candidate_user_id: new_user_ids).delete_all
      DuplicateReviewCase.where(id: case_ids).delete_all
      GuardianRelationship.where('guardian_id IN (?) OR dependent_id IN (?)', new_user_ids, new_user_ids).delete_all
      Event.where('user_id IN (?) OR (auditable_type = ? AND auditable_id IN (?))', new_user_ids, 'User', new_user_ids).delete_all
      User.where(id: new_user_ids).update_all(merged_into_user_id: nil)
      User.where(id: new_user_ids).delete_all
    end
  end
end
