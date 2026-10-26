# frozen_string_literal: true

module Admin
  # Application analytics, such as pain points.
  class ApplicationAnalyticsController < Admin::BaseController
    # GET /admin/application_analytics/pain_points
    def pain_points
      safe_assign(:analysis_results, Application.pain_point_analysis)
    end
  end
end
