# frozen_string_literal: true

require 'test_helper'

class ActivityHistoryHelperTest < ActionView::TestCase
  test 'formats known training actions' do
    event = Event.new(
      action: 'training_rescheduled',
      metadata: {
        old_scheduled_for: 2.days.from_now.iso8601,
        new_scheduled_for: 3.days.from_now.iso8601,
        reason: 'Trainer unavailable',
        location: 'Library'
      }
    )

    assert_equal 'Training Rescheduled', activity_label(event)
    assert_includes activity_detail(event), 'Trainer unavailable'
    assert_includes activity_detail(event), 'Library'
  end

  test 'formats known evaluation actions' do
    event = Event.new(
      action: 'evaluation_completed',
      metadata: {
        evaluation_date: Time.current.iso8601,
        products_tried_count: 2,
        recommended_products_count: 1,
        recommended_product_names: ['iPad Air']
      }
    )

    assert_equal 'Evaluation Completed', activity_label(event)
    assert_includes activity_detail(event), 'Products tried: 2'
    assert_includes activity_detail(event), 'iPad Air'
  end

  test 'formats application fulfillment source labels' do
    event = Event.new(action: 'equipment_po_sent', metadata: { date: Date.current.iso8601 })

    assert_equal 'PO Sent to Vendor', activity_label(event)
    assert_equal 'Application Fulfillment', activity_source_label(event)
  end

  test 'handles missing metadata gracefully' do
    event = Event.new(action: 'evaluation_scheduled', metadata: {})

    assert_equal 'No additional details recorded', activity_detail(event)
  end

  test 'uses actor name when available' do
    user = create(:admin, first_name: 'Ada', last_name: 'Lovelace')
    event = Event.new(action: 'evaluation_scheduled', user: user, metadata: {})

    assert_equal 'Ada Lovelace', activity_actor_name(event)
  end

  test 'uses evaluation constituent as activity subject' do
    constituent = create(:constituent, first_name: 'Alice', last_name: 'Doe')
    evaluation = create(:evaluation, constituent: constituent)
    event = Event.new(action: 'evaluation_scheduled', auditable: evaluation, metadata: {})

    assert_equal 'Alice Doe', activity_subject_name(event)
  end

  test 'uses application constituent as activity subject for fulfillment events' do
    constituent = create(:constituent, first_name: 'Pat', last_name: 'Portal')
    application = create(:application, :old_enough_for_new_application, user: constituent)
    event = Event.new(action: 'equipment_bids_sent', auditable: application, metadata: {})

    assert_equal 'Pat Portal', activity_subject_name(event)
  end

  test 'falls back to evaluation metadata for activity subject' do
    constituent = create(:constituent, first_name: 'Morgan', last_name: 'Metadata')
    evaluation = create(:evaluation, constituent: constituent)
    event = Event.new(action: 'evaluation_completed', metadata: { evaluation_id: evaluation.id.to_s })

    assert_equal 'Morgan Metadata', activity_subject_name(event)
  end
end
