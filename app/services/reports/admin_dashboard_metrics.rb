# frozen_string_literal: true

module Reports
  # The admin dashboard's counts. Most are cached for five minutes to reduce queries. The print queue and the
  # reassignment queues are read on every call so they stay current. The trainer assignment writers and the
  # training request service call expire! because they change the training request count; other writers, such as
  # Application#request_evaluation!, leave the cached counts to the TTL. The cache key lives here and nowhere else.
  class AdminDashboardMetrics
    CACHE_KEY = 'admin_dashboard_metrics'
    CACHE_TTL = 5.minutes

    # These metrics have local owners outside the reporting service.
    EXCLUDED_REPORTING_KEYS = %w[
      open_applications_count pending_services_count
      pipeline_chart_data status_chart_data combined_pipeline_chart_data combined_status_chart_data
      draft_count submitted_count in_review_count approved_count rejected_count in_progress_count
      draft_and_needs_info_count
    ].freeze

    def self.call
      new.call
    end

    # Cache expiry runs after the write it follows has committed, so a failure here must not fail that write.
    def self.expire!
      Rails.cache.delete(CACHE_KEY)
    rescue StandardError => e
      Rails.logger.warn "[AdminDashboardMetrics] Cache expiry failed (non-fatal): #{e.class.name}"
    end

    # @return [Hash{Symbol => Object}] Counts and chart data keyed by metric name
    def call
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { cached_metrics }.merge(current_metrics)
    end

    private

    def cached_metrics
      metrics = {
        open_applications_count: Application.active.count,
        pending_services_count: Application.where(status: :approved).count
      }
      metrics.merge!(reporting_metrics)
      metrics.merge!(
        proofs_needing_review_count: Application.with_proofs_needing_review.distinct.count,
        disability_certs_to_review_count: Application.where.not(status: %i[rejected archived])
                                                     .where(disability_certification_status: :received).count,
        digitally_signed_needs_review_count: Application.where(document_signing_status: :signed)
                                                        .where.not(disability_certification_status: :approved).count,
        training_requests_count: Application.with_pending_training_request.count,
        evaluation_requests_count: Application.with_pending_evaluation_request.count
      )
    end

    def current_metrics
      {
        print_queue_pending_count: PrintQueueItem.unreleased.count,
        evaluations_needing_reassignment_count: Application.needing_evaluator_reassignment.count,
        training_needing_reassignment_count: Application.needing_trainer_reassignment.count
      }
    end

    def reporting_metrics
      result = Applications::ReportingService.new.generate_index_data
      return {} unless result.is_a?(BaseService::Result) && result.success?

      result.data.to_h.each_with_object({}) do |(key, value), metrics|
        next if EXCLUDED_REPORTING_KEYS.include?(key.to_s) || key.to_s.blank? || value.nil?

        metrics[key] = value
      end
    end
  end
end
