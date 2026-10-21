# frozen_string_literal: true

module ActionFormErrorsHelper
  def action_form_action_errors(action, form_errors:)
    form_errors.fetch(action, {}).with_indifferent_access
  end

  def action_form_field_errors(action, attribute, form_errors:)
    Array(action_form_action_errors(action, form_errors: form_errors)[attribute])
  end

  def action_form_field_error_id(action, attribute)
    "#{action.to_s.dasherize}-#{attribute.to_s.dasherize}-error"
  end

  def action_form_field_aria(action, attributes, form_errors:, describedby: nil)
    error_attributes = Array(attributes).select do |attribute|
      action_form_field_errors(action, attribute, form_errors: form_errors).any?
    end
    descriptions = [describedby, *error_attributes.map { |attribute| action_form_field_error_id(action, attribute) }]

    { invalid: (true if error_attributes.any?), describedby: descriptions.compact.join(' ').presence }
  end

  def action_form_action_error_items(action, form, field_targets, form_errors:)
    action_form_action_errors(action, form_errors: form_errors).flat_map do |attribute, messages|
      target = field_targets.fetch(attribute.to_sym) { form&.field_id(attribute) unless attribute.to_sym == :base }
      Array(messages).map { |message| { message: message, target: target } }
    end
  end
end
