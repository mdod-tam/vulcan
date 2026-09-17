# frozen_string_literal: true

require 'digest'
require 'openssl'
require 'securerandom'
require 'timeout'

module DuplicateReconciliation
  # Production-safe discovery probe that evaluates the state of duplicate review cases,
  # review flags (needs_duplicate_review), dynamic matching volume, and guardian relationships.
  #
  # Design guarantees:
  # 1. Zero in-memory quadratic expansion or unbounded array loading.
  # 2. Database aggregates (COUNT, GROUP BY, HAVING, CTEs) execute in SQL.
  # 3. Database-enforced read-only transaction (SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY).
  # 4. Total task deadline actively enforced via dynamic per-query statement timeouts.
  # 5. Default output is strictly aggregate, with zero PII, topology masking, and HMAC-keyed pseudonyms.
  # 6. Correct flag-drift definition: counts constituents with needs_duplicate_review = true
  #    who have neither an open case nor an unresolved current Name+DOB pair.
  # 7. Fails closed if invoked within an open transaction to preserve top-level repeatable-read guarantees.
  # SQL queries and CTE definitions for DiscoveryProbe
  module DiscoveryQueries
    NO_OPEN_CASE_SQL = <<~SQL.squish
      users.type = 'Users::Constituent'
      AND users.needs_duplicate_review = true
      AND NOT EXISTS (
        SELECT 1 FROM duplicate_review_cases drc
        WHERE drc.status = 0 AND drc.subject_user_id = users.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM duplicate_review_case_candidates drcc
        JOIN duplicate_review_cases drc ON drc.id = drcc.duplicate_review_case_id
        WHERE drc.status = 0 AND drcc.candidate_user_id = users.id
      )
    SQL

    WITHOUT_OPEN_CASE_COUNT_SQL = "SELECT COUNT(*) FROM users WHERE #{NO_OPEN_CASE_SQL}".freeze

    OPEN_CASE_UNFLAGGED_COUNT_SQL = <<~SQL.squish
      SELECT COUNT(DISTINCT u.id)
      FROM users u
      WHERE u.type = 'Users::Constituent'
        AND (u.needs_duplicate_review = false OR u.needs_duplicate_review IS NULL)
        AND (
          EXISTS (SELECT 1 FROM duplicate_review_cases drc WHERE drc.status = 0 AND drc.subject_user_id = u.id)
          OR EXISTS (
            SELECT 1 FROM duplicate_review_case_candidates drcc
            JOIN duplicate_review_cases drc ON drc.id = drcc.duplicate_review_case_id
            WHERE drc.status = 0 AND drcc.candidate_user_id = u.id
          )
        )
    SQL

    CLUSTERS_BASE_SQL = <<~SQL.squish
      FROM users
      WHERE type = 'Users::Constituent'
        AND merged_into_user_id IS NULL
        AND (status IS NULL OR status = 1)
        AND first_name IS NOT NULL AND first_name != ''
        AND last_name IS NOT NULL AND last_name != ''
        AND date_of_birth IS NOT NULL
      GROUP BY LOWER(first_name), LOWER(last_name), date_of_birth
      HAVING COUNT(*) > 1
    SQL

    CLUSTERS_SUMMARY_SQL = <<~SQL.squish
      WITH clusters AS (SELECT COUNT(*) AS cluster_size #{CLUSTERS_BASE_SQL})
      SELECT COUNT(*) AS cluster_count,
             COALESCE(SUM(cluster_size * (cluster_size - 1) / 2), 0) AS total_pairs,
             COALESCE(MAX(cluster_size), 0) AS max_cluster_size
      FROM clusters
    SQL

    CLUSTERS_DISTRIBUTION_SQL = <<~SQL.squish
      WITH clusters AS (SELECT COUNT(*) AS cluster_size #{CLUSTERS_BASE_SQL})
      SELECT cluster_size, COUNT(*) AS group_count FROM clusters GROUP BY cluster_size ORDER BY cluster_size
    SQL

    CLUSTERS_AUDIT_SQL = <<~SQL.squish
      SELECT LOWER(first_name) AS fn, LOWER(last_name) AS ln, date_of_birth AS dob, COUNT(*) AS cluster_size
      #{CLUSTERS_BASE_SQL}
      ORDER BY COUNT(*) DESC, LOWER(last_name), LOWER(first_name), date_of_birth LIMIT $1
    SQL

    DEP_COUNTS_CTE_SQL = 'SELECT dependent_id, COUNT(*) AS g_count FROM guardian_relationships GROUP BY dependent_id'
    GUARDIAN_DISTRIBUTION_SQL = <<~SQL.squish
      WITH dep_counts AS (#{DEP_COUNTS_CTE_SQL})
      SELECT g_count, COUNT(*) AS dep_count FROM dep_counts GROUP BY g_count ORDER BY g_count
    SQL
    MULTI_GUARDIAN_DEPS_COUNT_SQL = "WITH dep_counts AS (#{DEP_COUNTS_CTE_SQL} HAVING COUNT(*) > 1) SELECT COUNT(*) FROM dep_counts".freeze

    MULTI_GUARDIAN_SAMPLES_SQL = <<~SQL.squish
      SELECT dependent_id, COUNT(*) AS guardian_count
      FROM guardian_relationships
      GROUP BY dependent_id
      HAVING COUNT(*) > 1
      ORDER BY dependent_id
      LIMIT $1
    SQL

    private

    def strict_case_ids_sql
      DuplicateReviewCase.strict_post_import_pairs.select(:id).to_sql
    end

    def malformed_samples_sql
      <<~SQL.squish
        SELECT drc.id, drc.status, drc.subject_user_id,
               (SELECT COUNT(*) FROM duplicate_review_case_candidates c WHERE c.duplicate_review_case_id = drc.id) AS candidate_count,
               drc.metadata->'reason_codes' AS reason_codes
        FROM duplicate_review_cases drc
        WHERE drc.source = 5
          AND drc.id NOT IN (#{strict_case_ids_sql})
        ORDER BY drc.id
        LIMIT $1
      SQL
    end

    def multi_case_pairs_sql
      <<~SQL.squish
        WITH strict_cases AS (
          SELECT drc.id, drc.subject_user_id AS u1
          FROM duplicate_review_cases drc
          WHERE drc.id IN (#{strict_case_ids_sql})
        ),
        strict_pairs AS (
          SELECT sc.u1, c.candidate_user_id AS u2
          FROM strict_cases sc
          JOIN duplicate_review_case_candidates c ON c.duplicate_review_case_id = sc.id
        ),
        multi_pairs AS (
          SELECT u1, u2, COUNT(*) AS case_count
          FROM strict_pairs
          GROUP BY u1, u2
          HAVING COUNT(*) > 1
        )
        SELECT u1, u2, case_count, COUNT(*) OVER () AS full_count
        FROM multi_pairs
        ORDER BY u1, u2
        LIMIT $1
      SQL
    end

    # NO_OPEN_CASE_SQL excludes participants with pending work. Remaining recognized
    # terminal pair evidence is resolved or stale in Population, not unreviewed.
    def unresolved_match_sql
      <<~SQL.squish
        users.merged_into_user_id IS NULL
        AND (users.status IS NULL OR users.status = 1)
        AND users.first_name IS NOT NULL AND users.first_name != ''
        AND users.last_name IS NOT NULL AND users.last_name != ''
        AND users.date_of_birth IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM users u2
          WHERE u2.id != users.id
            AND u2.type = 'Users::Constituent'
            AND u2.merged_into_user_id IS NULL
            AND (u2.status IS NULL OR u2.status = 1)
            AND u2.first_name IS NOT NULL AND u2.first_name != ''
            AND u2.last_name IS NOT NULL AND u2.last_name != ''
            AND u2.date_of_birth IS NOT NULL
            AND LOWER(u2.first_name) = LOWER(users.first_name)
            AND LOWER(u2.last_name) = LOWER(users.last_name)
            AND u2.date_of_birth = users.date_of_birth
            AND NOT EXISTS (
              SELECT 1 FROM (
                #{DuplicateReviewCase.reconciliation_pairs.resolved_cases
                                     .select(:subject_user_id, 'duplicate_review_case_candidates.candidate_user_id').to_sql}
              ) pair_cases
              WHERE (pair_cases.subject_user_id = users.id AND pair_cases.candidate_user_id = u2.id)
                 OR (pair_cases.subject_user_id = u2.id AND pair_cases.candidate_user_id = users.id)
            )
        )
      SQL
    end

    def true_drift_where_sql
      "#{NO_OPEN_CASE_SQL} AND NOT (#{unresolved_match_sql})"
    end

    def true_drift_count_sql
      "SELECT COUNT(*) FROM users WHERE #{true_drift_where_sql}"
    end

    def drift_candidates_with_sql_match_sql
      <<~SQL.squish
        SELECT users.id, users.date_of_birth FROM users
        WHERE #{NO_OPEN_CASE_SQL} AND #{unresolved_match_sql}
        ORDER BY users.id LIMIT $1
      SQL
    end

    def malformed_open_participants_sql
      <<~SQL.squish
        WITH malformed_open_cases AS (
          SELECT drc.id, drc.subject_user_id
          FROM duplicate_review_cases drc
          WHERE drc.source = 5 AND drc.status = 0
            AND drc.id NOT IN (#{strict_case_ids_sql})
        )
        SELECT COUNT(DISTINCT participant_id)
        FROM (
          SELECT subject_user_id AS participant_id FROM malformed_open_cases WHERE subject_user_id IS NOT NULL
          UNION
          SELECT candidate_user_id AS participant_id FROM duplicate_review_case_candidates
          WHERE duplicate_review_case_id IN (SELECT id FROM malformed_open_cases) AND candidate_user_id IS NOT NULL
        ) p
      SQL
    end

    def drift_samples_sql
      "SELECT users.id FROM users WHERE #{true_drift_where_sql} ORDER BY users.id LIMIT $1"
    end
  end

  class DiscoveryProbe
    include DiscoveryQueries

    DEFAULT_STATEMENT_TIMEOUT_MS = 15_000
    DEFAULT_SAMPLE_LIMIT = 5
    DEFAULT_CLUSTER_LIMIT = 500

    Result = Data.define(
      :provenance,
      :case_metrics,
      :flag_metrics,
      :matching_metrics,
      :guardian_metrics,
      :samples
    )

    def initialize(statement_timeout_ms: DEFAULT_STATEMENT_TIMEOUT_MS, sample_limit: DEFAULT_SAMPLE_LIMIT,
                   cluster_limit: DEFAULT_CLUSTER_LIMIT)
      @statement_timeout_ms = Integer(statement_timeout_ms)
      @sample_limit = Integer(sample_limit)
      @cluster_limit = Integer(cluster_limit)
      @salt = SecureRandom.hex(16)
    end

    def call(detailed_pii: false)
      with_read_only_transaction do
        provenance = collect_provenance
        assert_within_deadline!
        case_metrics, malformed_samples, multi_case_samples = collect_case_metrics(detailed_pii: detailed_pii)
        assert_within_deadline!
        flag_metrics, flag_discrepancy_samples = collect_flag_metrics(detailed_pii: detailed_pii)
        assert_within_deadline!
        matching_metrics, largest_group_sample = collect_matching_metrics
        assert_within_deadline!
        guardian_metrics, multi_guardian_samples = collect_guardian_metrics(detailed_pii: detailed_pii)
        assert_within_deadline!

        samples = {
          malformed_cases: malformed_samples,
          multi_case_pairs: multi_case_samples,
          flag_discrepancies: flag_discrepancy_samples,
          largest_matching_group: largest_group_sample,
          multi_guardian_dependents: multi_guardian_samples
        }

        Result.new(
          provenance: provenance,
          case_metrics: case_metrics,
          flag_metrics: flag_metrics,
          matching_metrics: matching_metrics,
          guardian_metrics: guardian_metrics,
          samples: samples
        )
      end
    end

    def render_summary(result, detailed_pii: false)
      [
        render_provenance_lines(result, detailed_pii),
        render_case_lines(result, detailed_pii),
        render_flag_lines(result, detailed_pii),
        render_matching_lines(result),
        render_guardian_lines(result, detailed_pii),
        '==========================================='
      ].flatten.join("\n")
    end

    def with_read_only_transaction
      raise 'DiscoveryProbe must not be executed inside an existing open transaction' unless ActiveRecord::Base.connection.open_transactions.zero?

      @deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + (@statement_timeout_ms / 1000.0)

      ActiveRecord::Base.transaction(isolation: :repeatable_read) do
        ActiveRecord::Base.connection.execute('SET TRANSACTION READ ONLY') if postgresql?
        yield
      end
    ensure
      @deadline = nil
    end

    def query_with_timeout
      apply_remaining_timeout!
      yield
    end

    private

    def render_provenance_lines(result, detailed_pii)
      lines = []
      lines << '=== PR 208 ARCHITECTURE DISCOVERY PROBE ==='
      lines << "Environment:  #{result.provenance[:rails_env]}"
      lines << "Timestamp:    #{result.provenance[:timestamp]}"
      lines << "Code SHA:     #{result.provenance[:code_sha]}"
      lines << "Database:     #{result.provenance[:database_adapter]} (fingerprint: #{result.provenance[:database_fingerprint]})"
      if result.provenance[:transaction_isolation]
        lines << "Transaction:  isolation=#{result.provenance[:transaction_isolation]}, read_only=#{result.provenance[:transaction_read_only]}"
      end
      lines << "PII Redacted: #{!detailed_pii}"
      lines << 'NOTE: SENSITIVE PII INCLUDED - HANDLE WITH CARE' if detailed_pii
      lines << ''
      lines
    end

    def render_case_lines(result, detailed_pii)
      lines = []
      lines << '--- 1. DUPLICATE REVIEW CASES INVENTORY ---'
      lines << "Total cases: #{result.case_metrics[:total_cases]}"
      result.case_metrics[:by_source_status_determination].each do |(source, status, determination), count|
        lines << "  source: #{source.to_s.ljust(28)} | status: #{status.to_s.ljust(22)} | determination: #{determination.to_s.ljust(28)} | count: #{count}"
      end
      lines << "Post-import cases total:     #{result.case_metrics[:post_import_total]}"
      lines << "  Conforming to strict shape: #{result.case_metrics[:post_import_strict_shape]}"
      lines << "  Malformed cases:            #{result.case_metrics[:post_import_malformed]}"
      lines << "Pairs with multiple cases:    #{result.case_metrics[:pairs_with_multiple_cases]}"
      lines.concat(render_malformed_case_sample_lines(result, detailed_pii))
      lines.concat(render_multi_case_pair_sample_lines(result, detailed_pii))
      lines << ''
      lines
    end

    def render_malformed_case_sample_lines(result, detailed_pii)
      return [] unless result.case_metrics[:post_import_malformed].positive? && result.samples[:malformed_cases].any?

      lines = ["  Sample malformed cases (#{result.samples[:malformed_cases].size}):"]
      result.samples[:malformed_cases].each do |c|
        lines << if detailed_pii && c[:id]
                   "    Case ##{c[:id]}: status=#{c[:status]}, subject_id=#{c[:subject_user_id]}, " \
                     "candidates=#{c[:candidate_count]}, reasons=#{sanitize_output_text(c[:reason_codes])}"
                 else
                   "    Case ref #{c[:ref]}: status=#{c[:status]}, candidate_count=#{c[:candidate_count]}"
                 end
      end
      lines
    end

    def render_multi_case_pair_sample_lines(result, detailed_pii)
      return [] unless result.case_metrics[:pairs_with_multiple_cases].positive? && result.samples[:multi_case_pairs].any?

      lines = ["  Sample duplicate-pair cases (#{result.samples[:multi_case_pairs].size}):"]
      result.samples[:multi_case_pairs].each do |p|
        lines << if detailed_pii && p[:pair_ids]
                   "    Pair #{p[:pair_ids].join('-')}: #{p[:case_count]} cases"
                 else
                   "    Pair ref #{p[:pair_ref]}: #{p[:case_count]} cases"
                 end
      end
      lines
    end

    def render_flag_lines(result, detailed_pii)
      lines = []
      lines << '--- 2. REVIEW FLAG INVENTORY (needs_duplicate_review) ---'
      lines << "Constituents with needs_duplicate_review = true: #{result.flag_metrics[:total_flagged_constituents]}"
      if result.flag_metrics[:drift_dob_audit_truncated]
        fm = result.flag_metrics
        lines << "  Flagged but NO open case and NO unresolved pair: >= #{fm[:flagged_without_open_case_or_match]} (true flag drift, lower bound; audit truncated)"
        lines << "  NOTE: Drift candidate DOB audit was bounded to #{fm[:audited_drift_candidates]} of #{fm[:total_drift_candidates]} candidates; " \
                 'additional corrupt matches may exist'
      else
        lines << "  Flagged but NO open case and NO unresolved pair: #{result.flag_metrics[:flagged_without_open_case_or_match]} (true flag drift)"
      end
      lines << "  Flagged but NO open case (may have match):      #{result.flag_metrics[:flagged_without_open_case]}"
      lines << "Constituents in open cases with flag = false:     #{result.flag_metrics[:open_case_constituents_unflagged]}"
      lines << "Malformed post-import open case participants:     #{result.flag_metrics[:malformed_open_case_participants]}"
      if result.flag_metrics[:flagged_without_open_case_or_match].positive? && result.samples[:flag_discrepancies].any?
        lines << "  Sample true drift records (#{result.samples[:flag_discrepancies].size}):"
        result.samples[:flag_discrepancies].each do |s|
          lines << (detailed_pii && s[:id] ? "    Constituent ##{s[:id]}" : "    Constituent ref #{s[:ref]}")
        end
      end
      lines << ''
      lines
    end

    def render_matching_lines(result)
      lines = []
      lines << '--- 3. CURRENT DYNAMIC MATCHING METRICS (Database Aggregates) ---'
      m = result.matching_metrics
      if m[:dob_audit_truncated]
        lines.concat(render_truncated_matching_lines(m, result.samples[:largest_matching_group]))
      else
        lines.concat(render_verified_matching_lines(m, result.samples[:largest_matching_group]))
      end
      lines << ''
      lines
    end

    def render_truncated_matching_lines(metrics, largest_group)
      lines = []
      lines << "Raw SQL Name + DOB clusters:  #{metrics[:raw_cluster_count]} (unverified; cluster audit truncated)"
      lines << "Raw SQL dynamic pair edges:   #{metrics[:raw_total_dynamic_pairs]}"
      lines << "  NOTE: Cluster DOB audit was bounded to #{metrics[:audited_clusters]} of #{metrics[:raw_cluster_count]} clusters; canonical totals not verified"
      if metrics[:invalid_dob_clusters].positive?
        lines << "  Invalid/undecryptable DOB clusters in sample: #{metrics[:invalid_dob_clusters]} of #{metrics[:audited_clusters]} audited " \
                 '(canonical exclusion incomplete)'
      end
      lines << 'Raw SQL cluster size distribution (cluster size => group count):'
      metrics[:raw_cluster_size_distribution].each do |size, count|
        pairs_each = size * (size - 1) / 2
        lines << "  Size #{size} (#{pairs_each} pairs each): #{count} group(s) -> #{count * pairs_each} total pairs"
      end
      if largest_group
        lines << "Largest verified cluster in sample: #{largest_group[:size]} constituents (#{largest_group[:pairs]} pairs) [cluster_ref: #{largest_group[:cluster_ref]}]"
      end
      lines
    end

    def render_verified_matching_lines(metrics, largest_group)
      lines = []
      lines << "Matching Name + DOB clusters: #{metrics[:cluster_count]}"
      lines << "Total dynamic pair edges:     #{metrics[:total_dynamic_pairs]}"
      if metrics[:invalid_dob_clusters].positive?
        lines << "  Invalid/undecryptable DOB clusters: #{metrics[:invalid_dob_clusters]} " \
                 "(excluded from verified dynamic matching; raw SQL clusters: #{metrics[:raw_cluster_count]})"
      end
      lines << 'Cluster size distribution (cluster size => group count):'
      metrics[:cluster_size_distribution].each do |size, count|
        pairs_each = size * (size - 1) / 2
        lines << "  Size #{size} (#{pairs_each} pairs each): #{count} group(s) -> #{count * pairs_each} total pairs"
      end
      lines << "Largest cluster: #{largest_group[:size]} constituents (#{largest_group[:pairs]} pairs) [cluster_ref: #{largest_group[:cluster_ref]}]" if largest_group
      lines
    end

    def render_guardian_lines(result, detailed_pii)
      lines = []
      lines << '--- 4. GUARDIAN RELATIONSHIP INVENTORY ---'
      lines << "Total GuardianRelationships: #{result.guardian_metrics[:total_relationships]}"
      lines << "Distinct dependents:         #{result.guardian_metrics[:distinct_dependents]}"
      lines << "Distinct guardians:          #{result.guardian_metrics[:distinct_guardians]}"
      lines << 'Guardians per dependent distribution (guardians => dependents):'
      result.guardian_metrics[:guardians_per_dependent_distribution].each do |g_count, dep_count|
        lines << "  #{g_count} guardian(s): #{dep_count} dependent(s)"
      end
      lines << "Dependents with multiple guardians: #{result.guardian_metrics[:multi_guardian_dependents_count]}"
      if result.samples[:multi_guardian_dependents].any?
        lines << 'Sample multi-guardian dependents:'
        result.samples[:multi_guardian_dependents].each do |m|
          if detailed_pii
            dep_name = sanitize_output_text(m[:dependent_name])
            lines << "  Dependent ##{m[:dependent_id]} (#{dep_name}): " \
                     "#{m[:guardian_count]} guardians (#{m[:relationship_count]} relationships)"
            m[:relationships].each do |r|
              g_name = sanitize_output_text(r[:guardian_name])
              r_type = sanitize_output_text(r[:type])
              lines << "    Rel ##{r[:id]}: guardian ##{r[:guardian_id]} (#{g_name}), " \
                       "type: #{r_type}, created: #{r[:created_at]}"
            end
            lines << "    ... and #{m[:omitted_relationships_count]} more relationship(s) omitted" if m[:omitted_relationships_count]&.positive?
          else
            lines << "  Dependent sample #{m[:ref]}: #{m[:guardian_count]} guardians (#{m[:relationship_count]} relationships)"
          end
        end
      end
      lines
    end

    def postgresql?
      ActiveRecord::Base.connection.adapter_name =~ /postgresql/i
    end

    def apply_remaining_timeout!
      return unless postgresql?

      deadline = @deadline || (Process.clock_gettime(Process::CLOCK_MONOTONIC) + (@statement_timeout_ms / 1000.0))
      remaining_ms = Integer((deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)) * 1000)
      raise Timeout::Error, "DiscoveryProbe exceeded total task deadline of #{@statement_timeout_ms}ms" if remaining_ms <= 0

      ActiveRecord::Base.connection.exec_query(
        "SELECT set_config('statement_timeout', $1, true)",
        'SQL',
        [ActiveRecord::Relation::QueryAttribute.new('value', "#{remaining_ms}ms", ActiveRecord::Type::String.new)]
      )
    end

    def assert_within_deadline!
      return unless @deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > @deadline

      raise Timeout::Error, "DiscoveryProbe exceeded total task deadline of #{@statement_timeout_ms}ms"
    end

    def opaque_ref(prefix, identifier)
      OpenSSL::HMAC.hexdigest('SHA256', @salt, "#{prefix}:#{identifier}")[0..7]
    end

    def sanitize_output_text(value)
      return '' if value.nil?

      str = value.to_s
      str = if str.encoding == Encoding::UTF_8
              str.valid_encoding? ? str : str.scrub
            else
              str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
            end

      str.gsub(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/) do |ch|
        case ch
        when "\n" then '\n'
        when "\r" then '\r'
        when "\t" then '\t'
        when "\e" then '\e'
        else
          cp = ch.ord
          if cp <= 0xFF
            format('\x%02X', cp)
          elsif cp <= 0xFFFF
            format('\u%04X', cp)
          else
            format('\u{%X}', cp)
          end
        end
      end
    end

    def collect_provenance
      conn = ActiveRecord::Base.connection
      db_config = ActiveRecord::Base.connection_db_config
      host_info = db_config.respond_to?(:host) ? db_config.host.to_s : ''
      db_info = db_config.respond_to?(:database) ? db_config.database.to_s : ''
      fingerprint = stable_database_fingerprint(conn.adapter_name, host_info, db_info)

      isolation = postgresql? ? query_with_timeout { conn.select_value('SHOW transaction_isolation') } : nil
      read_only = postgresql? ? query_with_timeout { conn.select_value('SHOW transaction_read_only') } : nil

      {
        rails_env: Rails.env,
        timestamp: Time.current.iso8601,
        code_sha: resolve_code_sha,
        database_adapter: conn.adapter_name,
        database_fingerprint: fingerprint,
        transaction_isolation: isolation,
        transaction_read_only: read_only
      }
    end

    def resolve_code_sha
      ENV['COMMIT_SHA'].presence ||
        ENV['HEROKU_BUILD_COMMIT'].presence ||
        ENV['SOURCE_VERSION'].presence ||
        ENV['HEROKU_SLUG_COMMIT'].presence ||
        ENV['KAMAL_VERSION'].presence ||
        ENV['GIT_SHA'].presence ||
        ENV['REVISION'].presence ||
        read_revision_file ||
        git_head_sha ||
        'unknown'
    end

    def read_revision_file
      rev_file = Rails.root.join('REVISION')
      File.read(rev_file).strip.presence if File.file?(rev_file)
    rescue SystemCallError
      nil
    end

    def git_head_sha
      `git rev-parse HEAD 2>/dev/null`.strip.presence
    end

    def stable_database_fingerprint(adapter, host_info, db_info)
      secret = Rails.application.key_generator.generate_key('DuplicateReconciliation::DiscoveryProbe:database_fingerprint', 32)
      OpenSSL::HMAC.hexdigest('SHA256', secret, "#{adapter}:#{host_info}:#{db_info}")[0..7]
    end

    def integer_bind(name, val)
      ActiveRecord::Relation::QueryAttribute.new(name.to_s, Integer(val), ActiveRecord::Type::Integer.new)
    end

    def collect_case_metrics(detailed_pii: false)
      counts = query_with_timeout { DuplicateReviewCase.group(:source, :status, :resolution_determination).count }
      total_cases = counts.values.sum
      post_import_total = query_with_timeout { DuplicateReviewCase.where(source: :post_import_reconciliation).count }

      strict_count = query_with_timeout { DuplicateReviewCase.strict_post_import_pairs.count }
      malformed_count = post_import_total - strict_count

      malformed_samples = query_malformed_case_samples(malformed_count, detailed_pii: detailed_pii)
      multi_case_samples, multi_case_count = query_multi_case_pairs(detailed_pii: detailed_pii)

      case_metrics = {
        total_cases: total_cases,
        by_source_status_determination: counts,
        post_import_total: post_import_total,
        post_import_strict_shape: strict_count,
        post_import_malformed: malformed_count,
        pairs_with_multiple_cases: multi_case_count
      }

      [case_metrics, malformed_samples, multi_case_samples]
    end

    def query_malformed_case_samples(malformed_count, detailed_pii:)
      return [] unless malformed_count.positive?

      rows = query_with_timeout do
        ActiveRecord::Base.connection.exec_query(malformed_samples_sql, 'SQL', [integer_bind('limit', @sample_limit)])
      end
      rows.map do |row|
        {
          id: detailed_pii ? row['id'] : nil,
          ref: opaque_ref('case', row['id']),
          status: row['status'],
          subject_user_id: detailed_pii ? row['subject_user_id'] : nil,
          candidate_count: row['candidate_count'].to_i,
          reason_codes: detailed_pii ? row['reason_codes'] : nil
        }
      end
    end

    def query_multi_case_pairs(detailed_pii:)
      rows = query_with_timeout do
        ActiveRecord::Base.connection.exec_query(multi_case_pairs_sql, 'SQL', [integer_bind('limit', @sample_limit)])
      end
      total_count = rows.empty? ? 0 : rows.first['full_count'].to_i
      samples = rows.map do |row|
        {
          pair_ids: detailed_pii ? [row['u1'], row['u2']] : nil,
          pair_ref: opaque_ref('pair', "#{row['u1']}_#{row['u2']}"),
          case_count: row['case_count'].to_i
        }
      end
      [samples, total_count]
    end

    def collect_flag_metrics(detailed_pii: false)
      total_flagged = query_with_timeout { Users::Constituent.where(needs_duplicate_review: true).count }

      sql_true_drift_count = query_with_timeout { ActiveRecord::Base.connection.select_value(true_drift_count_sql).to_i }
      without_open_case_count = query_with_timeout { ActiveRecord::Base.connection.select_value(WITHOUT_OPEN_CASE_COUNT_SQL).to_i }
      open_case_unflagged_count = query_with_timeout { ActiveRecord::Base.connection.select_value(OPEN_CASE_UNFLAGGED_COUNT_SQL).to_i }
      malformed_open_participants_count = query_with_timeout { ActiveRecord::Base.connection.select_value(malformed_open_participants_sql).to_i }

      candidates_with_sql_match_count = without_open_case_count - sql_true_drift_count
      corrupt_dob_drift_ids, drift_truncated, audited_candidates_count = audit_sql_match_dob_drift(candidates_with_sql_match_count)
      true_drift_lower_bound = sql_true_drift_count + corrupt_dob_drift_ids.size

      discrepancy_samples = query_drift_samples(
        sql_true_drift_count,
        corrupt_dob_drift_ids,
        detailed_pii: detailed_pii
      )

      flag_metrics = {
        total_flagged_constituents: total_flagged,
        flagged_without_open_case_or_match: true_drift_lower_bound,
        drift_dob_audit_truncated: drift_truncated,
        audited_drift_candidates: audited_candidates_count,
        total_drift_candidates: candidates_with_sql_match_count,
        flagged_without_open_case: without_open_case_count,
        open_case_constituents_unflagged: open_case_unflagged_count,
        malformed_open_case_participants: malformed_open_participants_count
      }

      [flag_metrics, discrepancy_samples]
    end

    def audit_sql_match_dob_drift(candidates_with_sql_match_count)
      return [[], false, 0] unless candidates_with_sql_match_count.positive?

      candidate_rows = query_with_timeout do
        ActiveRecord::Base.connection.exec_query(
          drift_candidates_with_sql_match_sql,
          'SQL',
          [integer_bind('limit', @cluster_limit)]
        )
      end

      is_truncated = candidates_with_sql_match_count > @cluster_limit
      corrupt_ids = []
      candidate_rows.each do |r|
        corrupt_ids << r['id'] unless valid_dob?(r['date_of_birth'])
      end
      [corrupt_ids, is_truncated, candidate_rows.length]
    end

    def query_drift_samples(sql_true_drift_count, corrupt_dob_drift_ids, detailed_pii:)
      samples = []
      if sql_true_drift_count.positive?
        rows = query_with_timeout do
          ActiveRecord::Base.connection.exec_query(drift_samples_sql, 'SQL', [integer_bind('limit', @sample_limit)])
        end
        samples = rows.rows.flatten.map do |uid|
          {
            id: detailed_pii ? uid : nil,
            ref: opaque_ref('user', uid)
          }
        end
      end

      if samples.size < @sample_limit && corrupt_dob_drift_ids.any?
        remaining = @sample_limit - samples.size
        corrupt_dob_drift_ids.first(remaining).each do |uid|
          samples << {
            id: detailed_pii ? uid : nil,
            ref: opaque_ref('user', uid)
          }
        end
      end

      samples
    end

    def collect_matching_metrics
      summary_row = query_with_timeout { ActiveRecord::Base.connection.select_one(CLUSTERS_SUMMARY_SQL) }
      raw_cluster_count = summary_row['cluster_count'].to_i
      raw_total_pairs = summary_row['total_pairs'].to_i

      if raw_cluster_count.zero?
        matching_metrics = {
          raw_cluster_count: 0,
          raw_total_dynamic_pairs: 0,
          raw_cluster_size_distribution: [],
          cluster_count: 0,
          total_dynamic_pairs: 0,
          cluster_size_distribution: [],
          dob_audit_truncated: false,
          audited_clusters: 0,
          invalid_dob_clusters: 0
        }
        return [matching_metrics, nil]
      end

      audit_rows = query_with_timeout do
        ActiveRecord::Base.connection.exec_query(
          CLUSTERS_AUDIT_SQL,
          'SQL',
          [integer_bind('limit', @cluster_limit)]
        )
      end

      is_truncated = raw_cluster_count > @cluster_limit
      valid_clusters, invalid_clusters = partition_audited_clusters(audit_rows)

      canonical_cluster_count, canonical_total_pairs, canonical_distribution, raw_distribution = calculate_cluster_metrics(
        raw_cluster_count,
        raw_total_pairs,
        valid_clusters,
        invalid_clusters,
        is_truncated
      )

      largest_group_sample = build_largest_group_sample(valid_clusters)

      matching_metrics = {
        raw_cluster_count: raw_cluster_count,
        raw_total_dynamic_pairs: raw_total_pairs,
        raw_cluster_size_distribution: raw_distribution,
        cluster_count: canonical_cluster_count,
        total_dynamic_pairs: canonical_total_pairs,
        cluster_size_distribution: canonical_distribution,
        dob_audit_truncated: is_truncated,
        audited_clusters: audit_rows.length,
        invalid_dob_clusters: invalid_clusters.size
      }

      [matching_metrics, largest_group_sample]
    end

    def partition_audited_clusters(audit_rows)
      valid = []
      invalid = []
      audit_rows.each do |row|
        if valid_dob?(row['dob'])
          valid << row
        else
          invalid << row
        end
      end
      [valid, invalid]
    end

    def calculate_cluster_metrics(raw_cluster_count, raw_total_pairs, valid_clusters, invalid_clusters, is_truncated)
      dist_rows = query_with_timeout { ActiveRecord::Base.connection.select_rows(CLUSTERS_DISTRIBUTION_SQL) }
      raw_dist = dist_rows.map { |sz, cnt| [sz.to_i, cnt.to_i] }

      if is_truncated
        [nil, nil, nil, raw_dist]
      elsif invalid_clusters.any?
        canonical_pairs = valid_clusters.sum do |c|
          sz = c['cluster_size'].to_i
          sz * (sz - 1) / 2
        end
        canonical_dist = valid_clusters.group_by { |c| c['cluster_size'].to_i }
                                       .map { |sz, g| [sz, g.size] }
                                       .sort_by(&:first)
        [valid_clusters.size, canonical_pairs, canonical_dist, raw_dist]
      else
        [raw_cluster_count, raw_total_pairs, raw_dist, raw_dist]
      end
    end

    def build_largest_group_sample(valid_clusters)
      largest_row = valid_clusters.first
      return unless largest_row

      max_size = largest_row['cluster_size'].to_i
      {
        size: max_size,
        pairs: max_size * (max_size - 1) / 2,
        cluster_ref: opaque_ref('cluster', "#{largest_row['fn']}:#{largest_row['ln']}:#{largest_row['dob']}")
      }
    end

    def valid_dob?(raw_dob)
      return false if raw_dob.blank?

      raw_value = Users::Constituent.type_for_attribute('date_of_birth').deserialize(raw_dob)
      return false if raw_value.blank?
      return true if raw_value.is_a?(Date)

      Date.parse(raw_value.to_s).is_a?(Date)
    rescue ActiveRecord::Encryption::Errors::Base, ArgumentError
      false
    end

    def collect_guardian_metrics(detailed_pii: false)
      total_relationships = query_with_timeout { GuardianRelationship.count }
      distinct_dependents = query_with_timeout { GuardianRelationship.distinct.count(:dependent_id) }
      distinct_guardians = query_with_timeout { GuardianRelationship.distinct.count(:guardian_id) }

      rows = query_with_timeout { ActiveRecord::Base.connection.select_rows(GUARDIAN_DISTRIBUTION_SQL) }
      distribution = rows.map do |g_count, dep_count|
        [g_count.to_i, dep_count.to_i]
      end

      multi_count = query_with_timeout { ActiveRecord::Base.connection.select_value(MULTI_GUARDIAN_DEPS_COUNT_SQL).to_i }
      multi_guardian_samples = query_multi_guardian_samples(multi_count, detailed_pii: detailed_pii)

      guardian_metrics = {
        total_relationships: total_relationships,
        distinct_dependents: distinct_dependents,
        distinct_guardians: distinct_guardians,
        guardians_per_dependent_distribution: distribution,
        multi_guardian_dependents_count: multi_count
      }

      [guardian_metrics, multi_guardian_samples]
    end

    def query_multi_guardian_samples(multi_count, detailed_pii:)
      return [] unless multi_count.positive?

      rows = query_with_timeout do
        ActiveRecord::Base.connection.exec_query(MULTI_GUARDIAN_SAMPLES_SQL, 'SQL', [integer_bind('limit', @sample_limit)])
      end

      rows.each_with_index.map do |row, idx|
        dep_id = row['dependent_id'].to_i
        g_count = row['guardian_count'].to_i

        if detailed_pii
          build_detailed_guardian_sample(dep_id, g_count)
        else
          {
            ref: opaque_ref('dep', idx + 1),
            guardian_count: g_count,
            relationship_count: g_count
          }
        end
      end
    end

    def build_detailed_guardian_sample(dep_id, g_count)
      dep = query_with_timeout { User.find_by(id: dep_id) }
      rels_scope = GuardianRelationship.where(dependent_id: dep_id).order(:id)
      total_rels = query_with_timeout { rels_scope.count }
      sampled_rels = query_with_timeout { rels_scope.limit(@sample_limit).eager_load(:guardian_user).to_a }
      omitted_count = [total_rels - @sample_limit, 0].max

      {
        dependent_id: dep_id,
        dependent_name: dep&.full_name,
        guardian_count: g_count,
        relationship_count: total_rels,
        omitted_relationships_count: omitted_count,
        relationships: sampled_rels.map do |r|
          {
            id: r.id,
            guardian_id: r.guardian_id,
            guardian_name: r.guardian_user&.full_name,
            type: r.relationship_type,
            created_at: r.created_at
          }
        end
      }
    end
  end
end
