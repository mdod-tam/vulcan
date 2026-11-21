# frozen_string_literal: true

require 'test_helper'

module Admin
  module Icanconnect
    class FilingPrepsControllerTest < ActionDispatch::IntegrationTest
      include IcanconnectTestSupport

      setup do
        start_icanconnect!
        @admin = create(:admin)
        @order, @unit = icc_order_with_unit
        sign_in_as(@admin, bypass_mfa_enrollment: true)
      end

      test 'invalid dates keep the filing page and date controls available' do
        get admin_icanconnect_filing_prep_path, params: { from: 'invalid', through: Date.current.iso8601 }
        assert_response :unprocessable_content
        assert_select 'h1', 'iCanConnect filing preparation'
        assert_select '[role="alert"]', 'Choose valid start and end dates.'
        assert_select 'input[name="from"]'
        assert_select 'input[name="through"]'
      end

      test 'invalid export filters render the HTML review page without generating an export' do
        %i[csv zip].each do |format|
          [{ from: 'invalid' }, { category: 'unknown' }, { view: 'unknown' }, { from: Date.tomorrow.iso8601, through: Date.current.iso8601 }].each do |filters|
            assert_no_difference -> { Event.where(action: 'export_generated').count } do
              get admin_icanconnect_filing_prep_path(format: format), params: filters
            end
            assert_response :unprocessable_content
            assert_equal 'text/html', response.media_type
            assert_select 'h1', 'iCanConnect filing preparation'
            assert_select '[role="alert"]'
            assert_select 'input[name="from"]'
            assert_select 'input[name="through"]'
          end
        end
      end

      test 'missing filing reference keeps unchanged selected costs for a corrected retry' do
        rows = [@unit, @order].each_with_index.to_h do |record, index|
          [index.to_s, filing_selection(record).merge('selected' => '1')]
        end
        attributes = { from: Date.current.iso8601, through: Date.current.iso8601, rows: rows, claim_period: 'Test period', external_reference: '' }
        patch admin_icanconnect_filing_prep_path, params: attributes
        assert_response :unprocessable_content
        assert_select 'input[type="checkbox"][checked]', count: 2
        assert_select 'input[name="claim_period"][value="Test period"]'
        assert_not @unit.reload.icc_claimed?
        patch admin_icanconnect_filing_prep_path, params: attributes.merge(external_reference: 'FILED-1')
        assert_response :redirect
        assert @unit.reload.icc_claimed?
        assert @order.reload.icc_claimed?
      end

      test 'stale costs require reselecting while unchanged selections remain checked' do
        _other_order, unchanged = icc_order_with_unit(application: @unit.application)
        rows = [@unit, unchanged].each_with_index.to_h do |record, index|
          [index.to_s, filing_selection(record).merge('selected' => '1')]
        end
        @unit.update!(serial_number: 'CHANGED-AFTER-REVIEW')
        patch admin_icanconnect_filing_prep_path, params: {
          from: Date.current.iso8601, through: Date.current.iso8601, rows: rows, claim_period: 'Test period', external_reference: 'FILED-1'
        }
        assert_response :unprocessable_content
        assert_select '[role="status"]', 'Changed or incomplete costs were unchecked. Review them and select them again.'
        assert_select "tr:has(input[value='EquipmentItem:#{@unit.id}']) input[type='checkbox'][checked]", count: 0
        assert_select "tr:has(input[value='EquipmentItem:#{unchanged.id}']) input[type='checkbox'][checked]", count: 1
        assert_not @unit.reload.icc_claimed?
        assert_not unchanged.reload.icc_claimed?
      end
    end
  end
end
