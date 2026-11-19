# frozen_string_literal: true

module Reports
  # Report data is cached for five minutes; operational queue and stage counts are read on every call.
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

    def self.approved_training_waiting_count
      Application.approved_awaiting_training.count
    end

    # Cache expiry runs after the write it follows has committed, so a failure here must not fail that write.
    def self.expire!
      Rails.cache.delete(CACHE_KEY)
    rescue StandardError => e
      Rails.logger.warn "[AdminDashboardMetrics] Cache expiry failed (non-fatal): #{e.class.name}"
    end

    # @return [Hash{Symbol => Object}] Counts and chart data keyed by metric name
    def call
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { reporting_metrics }.merge(current_metrics)
    end

    private

    def current_metrics
      stage_counts = approved_stage_counts
      {
        open_applications_count: Application.active.count,
        pending_services_count: Application.status_approved.count,
        active_awaiting_proofs_count: Application.awaiting_proofs.count,
        active_cert_requests_needed_count: Application.certifications_needing_request.count,
        active_awaiting_certifications_count: Application.active.certifications_awaiting_provider.count,
        active_proofs_needing_review_count: Application.active.awaiting_proof_review.count,
        active_disability_certs_to_review_count: Application.active.certifications_needing_review.count,
        approved_stage_counts: stage_counts,
        approved_stage_group_counts: Applications::ApprovedPipeline::STAGE_FILTERS.transform_values do |filter|
          filter.fetch(:stages).sum { |stage| stage_counts[stage] }
        end,
        approved_training_waiting_count: self.class.approved_training_waiting_count,
        print_queue_pending_count: PrintQueueItem.unreleased.count
      }
    end

    def approved_stage_counts
      applications = Application.status_approved.fulfillment_type_equipment.to_a
      Application.preload_equipment_fulfillment(applications, include_display_details: false)
      applications.each_with_object(Hash.new(0)) do |application, counts|
        counts[application.equipment_fulfillment_stage.stage] += 1
      end
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
