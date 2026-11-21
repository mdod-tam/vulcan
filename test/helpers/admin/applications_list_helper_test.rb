# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsListHelperTest < ActionView::TestCase
    include ApplicationsListHelper
    include EquipmentHelper

    test 'sort links retain filter context and reset pagination' do
      query = ActionController::Parameters.new(view: 'review', status: 'awaiting_proof', q: 'River',
                                               managing_guardian_q: 'Guardian', for_minors: 'true', page: '4',
                                               sort: 'applicant', direction: 'asc', unrelated: 'discard')

      @controller.params = query
      link = Nokogiri::HTML.fragment(view.application_sort_link('Applicant', :applicant)).at_css('a')
      values = Rack::Utils.parse_query(URI.parse(link['href']).query)

      assert_equal 'review', values['view']
      assert_equal 'awaiting_proof', values['status']
      assert_equal 'River', values['q']
      assert_equal 'Guardian', values['managing_guardian_q']
      assert_equal 'true', values['for_minors']
      assert_equal 'desc', values['direction']
      assert_not values.key?('page')
      assert_not values.key?('unrelated')
      assert_equal 'applications_list', link['data-turbo-frame']
      assert_equal 'ascending', view.application_sort_aria(:applicant)
      assert_equal 'none', view.application_sort_aria(:status)
    end

    test 'first status sort selects longest duration first' do
      @controller.params = ActionController::Parameters.new
      link = Nokogiri::HTML.fragment(view.application_sort_link('Status', :status)).at_css('a')
      values = Rack::Utils.parse_query(URI.parse(link['href']).query)

      assert_equal 'status', values['sort']
      assert_equal 'desc', values['direction']
      assert_includes link['aria-label'], 'time in status'
    end

    test 'status age uses the selected status timestamp including same-day entries' do
      travel_to Time.zone.local(2026, 11, 10, 12) do
        application = Struct.new(:current_status_entered_at).new(31.days.ago)
        assert_equal '(31 days)', application_status_age(application)

        application.current_status_entered_at = 2.hours.ago
        assert_equal '(0 days)', application_status_age(application)

        application.current_status_entered_at = nil
        assert_nil application_status_age(application)
      end
    end

    test 'pipeline tasks open PO entry for one bid and retain scoped lists for multiple bids or orders' do
      application = build_stubbed(:application)
      row = Struct.new(:application, :stage, :action_context, :voucher, :evaluation)
                  .new(application, :awaiting_bid_award, { bid_group_ids: [10] }, nil, nil)
      assert_equal new_admin_purchase_order_path(bid_group_id: 10, return_context: { application_id: application.id, tab: 'needs_ordering' }),
                   approved_pipeline_action_path(row)

      row.action_context = { bid_group_ids: [10, 11] }
      assert_equal admin_bid_groups_path(application_id: application.id), approved_pipeline_action_path(row)

      row.stage = :ready_to_send_po
      row.action_context = { purchase_order_ids: [10, 11] }
      assert_equal admin_purchase_orders_path(application_id: application.id, state: 'unsent'), approved_pipeline_action_path(row)

      row.stage = :awaiting_shipment
      row.action_context = {}
      assert_equal admin_equipment_index_path(application_id: application.id, tab: 'ordered'), approved_pipeline_action_path(row)

      row.action_context = { source: 'stock' }
      assert_equal admin_equipment_index_path(application_id: application.id, tab: 'ordered', source: 'stock'), approved_pipeline_action_path(row)
    end

    test 'pipeline date options use approval windows without fiscal creation filters' do
      values = application_date_range_options(view: 'pipeline').map(&:last)

      assert_equal ['', 'last_30', 'last_60', 'last_90', 'last_120', 'last_12_months'], values
      assert_includes application_date_range_options(view: 'all').map(&:last), 'current_fy'
    end

    test 'fulfillment captions group phone variants and summarize additional device families' do
      need = create(:equipment_need, product: create(:product, manufacturer: 'Apple', model_number: 'iPhone 18 Pro Max 512GB Deep Blue'))
      row = Struct.new(:application).new(need.application)
      assert_equal 'iPhone', approved_pipeline_device_summary(row)

      create(:equipment_need, application: row.application, product: create(:product, manufacturer: 'Apple', model_number: 'iPhone18 Pro 256GB Silver'))
      row.application.reload
      assert_equal 'iPhone', approved_pipeline_device_summary(row)

      create(:equipment_need, application: row.application, product: create(:product, manufacturer: 'Apple', model_number: 'iPad Pro 13-inch 2TB Wi-Fi Silver'))
      row.application.reload
      assert_equal 'iPhone + 1 more', approved_pipeline_device_summary(row)
    end

    test 'fulfillment captions use a short model or the product name without listing manufacturers' do
      need = create(:equipment_need, product: create(:product, model_number: 'BrailleSense Polaris Mini with keyboard'))
      row = Struct.new(:application).new(need.application)
      assert_equal 'BrailleSense Polaris...', approved_pipeline_device_summary(row)

      need.update!(product: create(:product, name: 'DotPad', model_number: nil, model_confirmed: false))
      row.application.reload
      assert_equal 'DotPad', approved_pipeline_device_summary(row)
    end

    test 'unselected fulfillment equipment links to selection while existing devices link to the queue' do
      application = create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment, equipment_needs_initialized_at: Time.current)
      row = Struct.new(:application, :stage, :action_context, :voucher, :evaluation).new(application, :needs_fulfillment, {}, nil, nil)
      assert_equal 'Device not yet selected', approved_pipeline_device_summary(row)
      assert_equal edit_admin_application_equipment_needs_path(application,
                                                               return_context: { application_id: application.id, tab: 'needs_ordering' }),
                   approved_pipeline_action_path(row)

      create(:equipment_need, application: application, disability_setup_group: nil)
      application.reload
      assert_equal admin_equipment_index_path(tab: 'needs_ordering', application_id: application.id), approved_pipeline_action_path(row)
    end
  end
end
