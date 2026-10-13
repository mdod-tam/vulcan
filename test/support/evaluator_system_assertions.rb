# frozen_string_literal: true

module EvaluatorSystemAssertions
  private

  def assert_single_action_error(id)
    assert_selector "##{id}[role=alert]"
    assert_selector '[role=alert]', count: 1
    assert_no_selector '[data-testid="flash-alert"]'
    action = id.delete_suffix('-errors').tr('-', '_')
    assert_selector "##{id} h3", text: I18n.t("evaluators.evaluations.forms.error_headings.#{action}")
  end

  def replace_product_selection(attribute, product = nil)
    all("input[name='evaluation[#{attribute}][]'][type='checkbox']").each(&:uncheck)
    find("input[name='evaluation[#{attribute}][]'][value='#{product.id}']").check if product
  end
end
