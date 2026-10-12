# frozen_string_literal: true

module Evaluators
  module EvaluationsHelper
    def evaluation_visible_form_actions(evaluation, can_manage:)
      return [] unless can_manage

      case evaluation.status
      when 'requested'
        evaluation.evaluation_date.blank? ? %i[schedule cancel] : []
      when 'scheduled', 'confirmed'
        actions = %i[submit_report cancel reschedule]
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

    def evaluation_action_errors(action, form_errors:)
      form_errors.fetch(action, {}).with_indifferent_access
    end

    def evaluation_field_errors(action, attribute, form_errors:)
      Array(evaluation_action_errors(action, form_errors: form_errors)[attribute])
    end

    def evaluation_field_error_id(action, attribute)
      "#{action.to_s.dasherize}-#{attribute.to_s.dasherize}-error"
    end

    def evaluation_field_aria(action, attributes, form_errors:, describedby: nil)
      error_attributes = Array(attributes).select do |attribute|
        evaluation_field_errors(action, attribute, form_errors: form_errors).any?
      end
      descriptions = [describedby, *error_attributes.map { |attribute| evaluation_field_error_id(action, attribute) }]

      { invalid: (true if error_attributes.any?), describedby: descriptions.compact.join(' ').presence }
    end

    def evaluation_action_error_items(action, form, field_targets, form_errors:)
      evaluation_action_errors(action, form_errors: form_errors).flat_map do |attribute, messages|
        target = field_targets.fetch(attribute.to_sym) { form&.field_id(attribute) unless attribute.to_sym == :base }
        Array(messages).map { |message| { message: message, target: target } }
      end
    end

    def evaluation_report_error_targets(outcome)
      {
        products_tried_field: 'products-tried-group',
        recommended_product_ids: outcome == 'catalog_products' ? 'catalog-recommendations-group' : 'recommendation-outcome-group',
        recommendation_outcome: 'recommendation-outcome-group'
      }
    end
  end
end
