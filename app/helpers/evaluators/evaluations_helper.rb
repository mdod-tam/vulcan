# frozen_string_literal: true

module Evaluators
  module EvaluationsHelper
    def evaluation_action_error_heading(action)
      t(
        "evaluators.evaluations.forms.error_headings.#{action}",
        locale: :en,
        default: t('evaluators.evaluations.forms.errors_heading', locale: :en)
      )
    end

    def evaluation_visible_form_actions(evaluation, can_manage:)
      return [] unless can_manage

      case evaluation.status
      when 'requested'
        return [] if evaluation.evaluation_date.present?

        actions = %i[schedule cancel]
        actions << :submit_report if evaluation.outside_specialist_report_allowed?(current_user)
        actions
      when 'scheduled', 'confirmed'
        actions = %i[submit_report reschedule cancel]
        actions.insert(1, :no_show) if evaluation.evaluation_date.present? && evaluation.evaluation_date < Time.current
        actions
      when 'cancelled', 'no_show', 'rescheduled'
        [:reschedule]
      when 'completed'
        [:supplemental_notes]
      else
        []
      end
    end

    def evaluation_assessment_source_options(evaluation)
      options = [['Outside-specialist consultation', 'outside_specialist']]
      options.unshift(['Direct assessment', 'direct_assessment']) unless evaluation.status_requested?
      options
    end

    def evaluation_recommendation_visible?(product, groups, selected_ids)
      product.eligible_for?(groups) || selected_ids.map(&:to_s).include?(product.id.to_s)
    end

    def evaluation_equipment_profile_values(evaluation, form_values)
      values = evaluation.application.suggested_shipping_snapshot
      values.merge(form_values.slice(*EquipmentShipping::FIELDS.map(&:to_s)))
    end

    def evaluation_report_error_targets
      {
        products_tried_inputs: 'products-tried-group',
        recommended_product_ids: 'catalog-recommendations-group',
        no_suitable_product: 'recommendation-outcome-group',
        program_disability_groups: 'program-groups-group'
      }
    end
  end
end
