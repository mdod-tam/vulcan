# frozen_string_literal: true

module Admin
  module ApplicationsListHelper
    APPLICATION_LIST_PARAMETERS = %i[
      view status filter date_range q managing_guardian_q dependent_q managing_guardian_id
      guardian_id dependent_id only_dependent_apps for_minors group stage sort direction program_group
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
      options = [['All', ''], %w[Active active], ['In progress', 'in_progress'], ['Awaiting proof', 'awaiting_proof'],
                 ['Reminder sent', 'reminder_sent'], ['Awaiting certification', 'awaiting_dcf']]
      if view == 'all'
        options.insert(2, %w[Draft draft])
        options.push(%w[Approved approved], %w[Rejected rejected], %w[Archived archived])
      end
      options
    end

    def approved_pipeline_stage_label(stage, stage_labels)
      stage_labels.fetch(stage.to_sym) do
        Applications::ApprovedPipeline::STAGE_FILTERS.fetch(stage.to_sym).fetch(:label)
      end
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
      return unless entered_at

      "(#{pluralize([((Time.current - entered_at) / 1.day).floor, 0].max, 'day')})"
    end

    def application_next_action_path(application)
      anchor = 'attachments-section' if ['Review proof', 'Review certification'].include?(application.next_action)
      admin_application_path(application.id, anchor: anchor)
    end

    def approved_pipeline_action_path(row)
      return admin_voucher_path(row.voucher) if row.voucher
      return evaluators_evaluation_path(row.evaluation) if row.stage == :awaiting_report && row.evaluation

      equipment_path = approved_pipeline_equipment_path(row.application, row)
      return equipment_path if equipment_path

      anchor = row.stage == :needs_evaluator ? 'evaluation-status-title' : 'admin-training-heading'
      admin_application_path(row.application, anchor:)
    end

    def approved_pipeline_equipment_path(application, work)
      case work.stage
      when :needs_fulfillment
        if Equipment::FulfillmentStage.new(application).equipment_selection_needed?
          edit_admin_application_equipment_needs_path(application, return_context: { application_id: application.id, tab: 'needs_ordering' })
        else
          admin_equipment_index_path(tab: 'needs_ordering', application_id: application.id)
        end
      when :awaiting_bid_award
        ids = work.action_context[:bid_group_ids]
        if ids.one?
          new_admin_purchase_order_path(bid_group_id: ids.sole, return_context: { application_id: application.id, tab: 'needs_ordering' })
        else
          admin_bid_groups_path(application_id: application.id)
        end
      when :ready_to_send_po
        ids = work.action_context[:purchase_order_ids]
        ids.one? ? admin_purchase_order_path(ids.sole) : admin_purchase_orders_path(application_id: application.id, state: 'unsent')
      when :awaiting_shipment then admin_equipment_index_path(tab: 'ordered', application_id: application.id, source: work.action_context[:source])
      when :shipment_recorded then admin_equipment_index_path(tab: 'shipped', application_id: application.id)
      end
    end

    def approved_pipeline_device_summary(row)
      equipment_device_summary(Equipment::FulfillmentStage.new(row.application).requests_to_fulfill.map(&:product))
    end

    def approved_pipeline_next_step(row)
      row.action_label == 'Enter bid number' ? 'Needs bid number' : "Next: #{row.action_label}"
    end

    def approved_pipeline_time(row)
      return 'Date unavailable' unless row.entered_at
      return "Completed #{row.entered_at.to_date.to_fs(:long)}" if Applications::ApprovedPipeline.terminal_stage?(row.stage)

      "#{pluralize(row.days, 'day')} waiting"
    end

    def approved_pipeline_secondary(outstanding)
      definition = Equipment::FulfillmentStage::DEFINITIONS.find { |entry| entry.key == outstanding.stage }
      text = "#{pluralize(outstanding.quantity, 'device')} · #{definition.label}"
      return "#{text} · Date unavailable" unless outstanding.entered_at

      days = Equipment::WaitTime.days_since(outstanding.entered_at)
      "#{text} · #{pluralize(days, 'day')}"
    end

    def approved_pipeline_empty_message(pipeline:, group:)
      return 'No approved applications match the current filters.' if pipeline.rows.empty?
      return 'No applications in this fulfillment group.' if pipeline.groups.fetch(group).empty?

      'No applications in this stage. Choose All stages to view this group.'
    end
  end
end
