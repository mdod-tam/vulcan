# frozen_string_literal: true

module Evaluators
  module EvaluationsHelper
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

    def evaluation_action_errors(action, form_errors:)
      form_errors.fetch(action, {}).with_indifferent_access
    end

    def evaluation_assessment_source_options(evaluation)
      options = [['Outside-specialist consultation', 'outside_specialist']]
      options.unshift(['Direct assessment', 'direct_assessment']) unless evaluation.status_requested?
      options
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

    def evaluation_report_error_targets
      {
        products_tried_inputs: 'products-tried-group',
        recommended_product_ids: 'catalog-recommendations-group',
        no_suitable_product: 'recommendation-outcome-group'
      }
    end
  end
end
