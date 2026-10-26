# frozen_string_literal: true

module FormTestHelper
  # Rails form checkboxes submit a hidden "0" and the checked "1" under one scalar name, so the last value wins.
  def checkbox_params(checked)
    checked ? '1' : '0'
  end

  # Helper method to create a set of checkbox parameters for multiple checkboxes
  # Returns a hash with the checkbox names as keys and the checkbox values as values
  def checkboxes_params(checkboxes)
    checkboxes.transform_values { |v| checkbox_params(v) }
  end

  # Helper method to assert that a checkbox is checked in the HTML response
  def assert_checkbox_checked(selector)
    assert_select "#{selector}[checked]", { count: 1 },
                  "Expected checkbox '#{selector}' to be checked, but it wasn't"
  end

  # Helper method to assert that a checkbox is not checked in the HTML response
  def assert_checkbox_not_checked(selector)
    assert_select "#{selector}:not([checked])", { count: 1 },
                  "Expected checkbox '#{selector}' not to be checked, but it was"
  end

  # Helper method to assert that a radio button is selected in the HTML response
  def assert_radio_selected(selector, value)
    assert_select "#{selector}[value='#{value}'][checked]", { count: 1 },
                  "Expected radio button '#{selector}' with value '#{value}' to be selected, but it wasn't"
  end

  # Helper method to assert that a select option is selected in the HTML response
  def assert_option_selected(select_selector, option_value)
    assert_select "#{select_selector} option[value='#{option_value}'][selected]", { count: 1 },
                  "Expected option with value '#{option_value}' to be selected in '#{select_selector}', but it wasn't"
  end

  # Helper method to assert that a form field has a specific value
  def assert_field_value(selector, value)
    assert_select "#{selector}[value='#{value}']", { count: 1 },
                  "Expected field '#{selector}' to have value '#{value}', but it didn't"
  end

  # Helper method to assert that a form field has an error
  def assert_field_has_error(field_name)
    assert_select ".field_with_errors input[name*='#{field_name}']", { count: 1 },
                  "Expected field '#{field_name}' to have an error, but it didn't"
  end

  # Helper method to assert that a form field does not have an error
  def assert_field_has_no_error(field_name)
    assert_select ".field_with_errors input[name*='#{field_name}']", { count: 0 },
                  "Expected field '#{field_name}' not to have an error, but it did"
  end

  # Helper method to assert that a form has a specific error message
  def assert_form_error_message(message)
    assert_select '.error-message, .field_with_errors .error, .invalid-feedback', { text: /#{message}/i },
                  "Expected form to have error message '#{message}', but it didn't"
  end

  # Helper method to assert that a form does not have a specific error message
  def assert_no_form_error_message(message)
    assert_select '.error-message, .field_with_errors .error, .invalid-feedback', { text: /#{message}/i, count: 0 },
                  "Expected form not to have error message '#{message}', but it did"
  end
end
