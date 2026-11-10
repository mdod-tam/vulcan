# frozen_string_literal: true

module Admin
  module ApplicationsListHelper
    APPLICATION_LIST_PARAMETERS = %i[
      view status filter date_range q managing_guardian_q dependent_q managing_guardian_id
      guardian_id dependent_id only_dependent_apps for_minors group stage sort direction
    ].freeze

    def application_list_path(**changes)
      query = params.permit(*APPLICATION_LIST_PARAMETERS).to_h.symbolize_keys
      admin_applications_path(query.merge(changes).compact)
    end

    def application_date_range_options(view:)
      options = [['All time', ''], ['Last 30 days', 'last_30'], ['Last 60 days', 'last_60'],
                 ['Last 90 days', 'last_90'], ['Last 120 days', 'last_120'], ['Last 12 months', 'last_12_months']]
      options.insert(1, ['Current FY', 'current_fy'], ['Previous FY', 'previous_fy']) unless view == 'pipeline'
      options
    end

    def application_status_filter_options(view:)
      options = [['All', ''], ['In progress', 'in_progress'], ['Awaiting proof', 'awaiting_proof'],
                 ['Reminder sent', 'reminder_sent'], ['Awaiting certification', 'awaiting_dcf']]
      if view == 'all'
        options.insert(1, %w[Active active], %w[Draft draft])
        options.push(%w[Approved approved], %w[Rejected rejected], %w[Archived archived])
      end
      options
    end

    def application_sort_link(label, column)
      selected = Applications::FilterService.sort_column(params) == column.to_s
      direction = Applications::FilterService.sort_direction(params)
      next_direction = if selected
                         direction == 'asc' ? 'desc' : 'asc'
                       else
                         Applications::FilterService.sort_direction(sort: column.to_s)
                       end
      indicator = if selected
                    direction == 'asc' ? '↑' : '↓'
                  else
                    '↕'
                  end
      sort_label = column.to_s == 'status' ? 'time in status' : label.downcase

      link_to application_list_path(sort: column, direction: next_direction),
              class: 'inline-flex items-center gap-1 text-primary-700 underline',
              aria: { label: "Sort by #{sort_label}, #{next_direction == 'asc' ? 'ascending' : 'descending'}" },
              data: { turbo_frame: 'applications_list', turbo_action: 'advance' } do
        safe_join([label, tag.span(indicator, aria: { hidden: true })], ' ')
      end
    end

    def application_sort_aria(column)
      return 'none' unless Applications::FilterService.sort_column(params) == column.to_s

      Applications::FilterService.sort_direction(params) == 'asc' ? 'ascending' : 'descending'
    end

    def application_status_age(application)
      entered_at = application.current_status_entered_at
      return 'Date unavailable' unless entered_at

      "(#{pluralize([((Time.current - entered_at) / 1.day).floor, 0].max, 'day')})"
    end

    def application_next_action_path(application)
      anchor = 'attachments-section' if ['Review proof', 'Review certification'].include?(application.next_action)
      admin_application_path(application.id, anchor: anchor)
    end

    def approved_pipeline_action_path(row)
      return admin_voucher_path(row.voucher) if row.voucher
      return evaluators_evaluation_path(row.evaluation) if row.stage == :report && row.evaluation

      anchor = case row.stage
               when :evaluator, :report then 'evaluation-status-title'
               when :po, :tracking, :recorded then 'equipment'
               when :none then 'admin-training-heading' if row.action_label == 'Open training'
               end
      admin_application_path(row.application, anchor: anchor)
    end
  end
end
