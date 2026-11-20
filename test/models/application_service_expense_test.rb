# frozen_string_literal: true

require 'test_helper'

class ApplicationServiceExpenseTest < ActiveSupport::TestCase
  include IcanconnectTestSupport

  setup do
    start_icanconnect!
    ensure_system_audit_actor!
    @admin = create(:admin)
    FeatureFlag.disable!(:vouchers_enabled)
  end

  test 'invoice edits do not requalify an unchanged performed service but changed dates and beneficiaries do' do
    application = approved_deafblind_application
    _order, unit = icc_order_with_unit(application: application)
    expense = ApplicationServiceExpense.create!(application: application, equipment_item: unit, category: 'travel', service_date: Date.current, amount: '25')
    application.update!(income_proof_status: :rejected)

    assert expense.update(vendor_invoice_number: 'AFTER-SERVICE', amount: '26'), expense.errors.full_messages.to_sentence
    assert_not ApplicationServiceExpense.new(application: application, equipment_item: unit, category: 'travel', service_date: Date.current).valid?
    expense.service_date = Date.current.prev_day
    assert_not expense.valid?
    assert_match(/approved.*income proof/i, expense.errors[:base].join)

    other_application = approved_deafblind_application
    _other_order, other_unit = icc_order_with_unit(application: other_application)
    other_application.update!(income_proof_status: :rejected)
    expense.reload.assign_attributes(application: other_application, equipment_item: other_unit)
    assert_not expense.valid?
    assert_match(/approved.*income proof/i, expense.errors[:base].join)
  end

  test 'every invoice edit still checks device ownership and ICC funding' do
    _order, unit = icc_order_with_unit
    expense = ApplicationServiceExpense.create!(application: unit.application, equipment_item: unit, category: 'travel', service_date: Date.current)
    mat_unit = create(:equipment_item, application: unit.application, funding_source: 'mat')
    expense.equipment_item = mat_unit
    expense.vendor_invoice_number = 'WRONG-FUNDING'
    assert_not expense.valid?
    assert_includes expense.errors[:equipment_item], 'must have ICC funding'
  end
end
