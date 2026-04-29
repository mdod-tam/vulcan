# frozen_string_literal: true

require 'test_helper'

class EvaluationTest < ActiveSupport::TestCase
  test 'creates a valid evaluation' do
    evaluation = create(:evaluation)
    assert evaluation.valid?
    assert_equal 'scheduled', evaluation.status
  end

  test 'creates a completed evaluation' do
    evaluation = create(:evaluation, :completed)
    assert evaluation.valid?
    assert_equal 'completed', evaluation.status
    assert evaluation.report_submitted
  end

  test 'creates an evaluation with custom attendees' do
    evaluation = create(:evaluation, :with_custom_attendees)
    assert_equal 1, evaluation.attendees.size
    assert_equal 'Alice Johnson', evaluation.attendees.first['name']
  end

  test 'attendees field preserves evaluator-entered text' do
    evaluation = Evaluation.new

    evaluation.attendees_field = 'family friend'

    assert_equal [{ 'name' => 'family friend' }], evaluation.attendees
    assert_equal ['family friend'], evaluation.attendee_display_values
    assert_equal 'family friend', evaluation.attendees_field
  end

  test 'attendee display remains compatible with legacy relationship values' do
    evaluation = Evaluation.new(attendees: [{ 'name' => 'Jane Doe', 'relationship' => 'Caregiver' }])

    assert_equal ['Jane Doe - Caregiver'], evaluation.attendee_display_values
    assert_equal 'Jane Doe - Caregiver', evaluation.attendees_field
  end

  test 'attendee display suppresses old not specified relationship fallback' do
    evaluation = Evaluation.new(attendees: [{ 'name' => 'family friend', 'relationship' => 'Not specified' }])

    assert_equal ['family friend'], evaluation.attendee_display_values
    assert_equal 'family friend', evaluation.attendees_field
  end

  test 'creates an evaluation with mobile devices' do
    evaluation = create(:evaluation, :with_mobile_devices)
    assert_equal 2, evaluation.products_tried.size
    iphone = Product.find_by(name: 'iPhone')
    pixel = Product.find_by(name: 'Pixel')
    assert_equal iphone.id, evaluation.products_tried.first['product_id']
    assert_equal pixel.id, evaluation.products_tried.second['product_id']
  end

  test 'allows administrators as evaluators through inherent capability' do
    evaluation = build(:evaluation, evaluator: create(:admin))

    assert evaluation.valid?, -> { evaluation.errors.full_messages.join(', ') }
  end

  test 'does not allow trainers as evaluators even with explicit can_evaluate capability' do
    trainer = create(:trainer)
    create(:role_capability, user: trainer, capability: 'can_evaluate')
    evaluation = build(:evaluation, evaluator: trainer)

    assert_not evaluation.valid?
    assert_includes evaluation.errors[:evaluator], 'must be an Evaluator or an administrator with evaluation capability'
  end
end
