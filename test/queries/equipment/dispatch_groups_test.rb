# frozen_string_literal: true

require 'test_helper'

module Equipment
  class DispatchGroupsTest < ActiveSupport::TestCase
    setup { FeatureFlag.disable!(:vouchers_enabled) }

    test 'dispatch groups one beneficiary destination and source across application history' do
      beneficiary = create(:constituent)
      first = create(:application, :approved, :with_all_proofs, user: beneficiary)
      second = create(:application, :approved, :with_all_proofs, user: beneficiary)
      product = create(:product)
      direct = create(:equipment_item, application: first, product:, purchase_order: create(:purchase_order, sent_at: 5.days.ago.to_date))
      same_recipient = create(:equipment_item, application: second, product:)
      other_destination = create(:equipment_item, application: first, product:, shipping_address_2: 'Separate unit')
      stock = create(:equipment_item, application: first, product:, fulfillment_source: 'existing_stock', purchase_order: nil,
                                      stock_received_on: 4.days.ago.to_date, stock_allocated_at: 1.day.ago, intake_provenance: 'Verified physical stock')
      other_beneficiary = create(:equipment_item, product:)
      unsent = create(:equipment_item, application: first, product:, purchase_order: create(:purchase_order, sent_at: nil))
      unallocated = create(:equipment_item, application: nil, product:, fulfillment_source: 'existing_stock', purchase_order: nil,
                                            stock_received_on: Date.current, intake_provenance: 'Verified shelf stock')

      groups = Queue.new(tab: 'ordered').dispatch_groups
      own_direct = groups.find { |group| group.items.map(&:id).sort == [direct.id, same_recipient.id].sort }
      assert own_direct
      assert_equal beneficiary.id, own_direct.beneficiary.id
      assert_equal direct.purchase_order.sent_at.to_time, own_direct.oldest_wait_at
      assert_equal 4, groups.size
      expected_ids = [direct, same_recipient, other_destination, stock, other_beneficiary].map(&:id).sort
      assert_equal expected_ids, groups.flat_map(&:items).map(&:id).sort
      assert_not_includes groups.flat_map(&:items).map(&:id), unsent.id
      assert_not_includes groups.flat_map(&:items).map(&:id), unallocated.id
      assert_equal expected_ids, Queue.new(tab: 'ordered', source: 'stock', product_id: product.id).dispatch_groups.flat_map(&:items).map(&:id).sort
      assert_equal [direct.id, other_destination.id, stock.id].sort,
                   Queue.new(tab: 'ordered', application_id: first.id, source: 'stock').dispatch_groups.flat_map(&:items).map(&:id).sort
    end

    test 'a removed setup group becomes review work while historical unit snapshots stay unchanged' do
      application = create(:application, :approved, :with_all_proofs, program_disability_groups: %w[deaf speech])
      need = create(:equipment_need, application:, disability_setup_group: 'deaf')
      shipped = create(:equipment_item, application:, disability_setup_group: 'deaf', shipped_at: Date.current, tracking_number: 'HISTORICAL')
      application.update!(program_disability_groups: ['speech'])
      assert_not need.reload.setup_ready?
      assert_equal 'deaf', need.disability_setup_group
      assert shipped.reload.setup_ready?
      assert_equal 'deaf', shipped.disability_setup_group
      assert_equal 'Prepare bid', application.reload.equipment_fulfillment_stage.action
    end
  end
end
