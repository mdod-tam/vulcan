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

  test 'selected trial inputs retain actual satisfaction and exclude unchecked products' do
    evaluation = build(:evaluation, :completed)
    products = create_list(:product, 3)
    inputs = products.zip(Evaluation::TRIAL_REACTIONS).to_h do |product, reaction|
      [product.id.to_s, { selected: '1', reaction: " #{reaction} " }]
    end
    evaluation.products_tried_inputs = inputs.merge('0' => { selected: '0', reaction: 'Not a rating' })

    assert evaluation.valid?, -> { evaluation.errors.full_messages.join(', ') }
    assert_equal products.map { |product| product.id.to_s }, evaluation.products_tried.pluck('product_id')
    assert_equal Evaluation::TRIAL_REACTIONS, evaluation.products_tried.pluck('reaction')
    assert_equal({ 'selected' => '1', 'reaction' => 'Satisfied' }, evaluation.products_tried_inputs.fetch(products.first.id.to_s))
  end

  test 'checked trials require a recognized rating and catalog product' do
    evaluation = build(:evaluation, :completed)
    product = evaluation.recommended_products.first
    [nil, '', 'Not recorded', 'Unknown'].each do |reaction|
      evaluation.products_tried_inputs = { product.id.to_s => { selected: '1', reaction: reaction } }

      assert_not evaluation.valid?
      assert_includes evaluation.errors[:products_tried].join, reaction.blank? ? 'requires a satisfaction rating' : 'must use Satisfied'
    end

    evaluation.products_tried_inputs = { '0' => { selected: '1', reaction: 'Neutral' } }
    assert_not evaluation.valid?
    assert_includes evaluation.errors[:products_tried], 'must reference catalog products'
  end

  test 'historical actual trial reactions survive supplemental notes without reclassification' do
    evaluation = create(:evaluation, :completed, :with_single_product)
    original = evaluation.products_tried

    evaluation.update!(post_completion_notes: 'Later observation')

    assert_equal original, evaluation.reload.products_tried
    assert_equal 'Very Satisfied', evaluation.products_tried_inputs.values.sole['reaction']
  end

  test 'allows administrators as evaluators through inherent capability' do
    evaluation = build(:evaluation, evaluator: create(:admin))

    assert evaluation.valid?, -> { evaluation.errors.full_messages.join(', ') }
  end

  test 'allows a trainer granted can_evaluate as an evaluator' do
    trainer = create(:trainer)
    create(:role_capability, user: trainer, capability: 'can_evaluate')
    evaluation = build(:evaluation, evaluator: trainer)

    assert evaluation.valid?, -> { evaluation.errors.full_messages.join(', ') }
  end

  test 'does not allow a trainer without the can_evaluate grant as an evaluator' do
    evaluation = build(:evaluation, evaluator: create(:trainer))

    assert_not evaluation.valid?
    assert_includes evaluation.errors[:evaluator], 'must be an active staff member with evaluation capability'
  end

  test 'a former evaluator who lost eligibility keeps unrelated edits and cancellation but cannot be newly assigned' do
    evaluator = create(:evaluator)
    evaluation = create(:evaluation, evaluator: evaluator)
    evaluator.update!(status: :inactive)

    assert evaluation.reload.update(working_notes: 'Unrelated note'), -> { evaluation.errors.full_messages.join(', ') }
    assert evaluation.update(status: :cancelled), -> { evaluation.errors.full_messages.join(', ') }

    reassigned = create(:evaluation)
    assert_not reassigned.update(evaluator: evaluator)
    assert_includes reassigned.errors[:evaluator], 'must be an active staff member with evaluation capability'
  end

  test 'new completion requires separately recorded actual appointment and submission times' do
    evaluation = create(:evaluation)

    assert_not evaluation.update(status: :completed)
    assert_includes evaluation.errors[:appointment_completed_at], "can't be blank"
    assert_includes evaluation.errors[:report_submitted_at], "can't be blank"
    assert_equal 'scheduled', evaluation.reload.status
  end

  test 'completion with blank notes yields one presence error' do
    evaluation = create(:evaluation)

    updated = evaluation.update(
      status: :completed, notes: ' ',
      appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current
    )

    assert_not updated
    assert_equal ["can't be blank"], evaluation.errors[:notes]
    assert_equal 'scheduled', evaluation.reload.status
  end

  test 'actual appointment cannot be recorded in the future' do
    evaluation = create(:evaluation)

    assert_not evaluation.update(status: :completed, appointment_completed_at: 1.day.from_now, report_submitted_at: Time.current)
    assert_includes evaluation.errors[:appointment_completed_at], 'cannot be in the future'
    assert_equal 'scheduled', evaluation.reload.status
  end

  test 'legacy completed record can receive supplemental notes without inventing timestamps' do
    evaluation = create(:evaluation, :completed)
    evaluation.update!(appointment_completed_at: nil, report_submitted_at: nil)

    assert_nil evaluation.appointment_completed_at
    assert_nil evaluation.report_submitted_at
    evaluation.update!(post_completion_notes: 'Supplemental observation')

    assert_equal 'completed', evaluation.reload.status
    assert_equal 'Supplemental observation', evaluation.post_completion_notes
    assert_nil evaluation.appointment_completed_at
    assert_nil evaluation.report_submitted_at
  end

  test 'completed reports sort by submission time with legacy unknowns last' do
    earlier_report = create(
      :evaluation, :completed,
      evaluation_date: 7.days.from_now,
      appointment_completed_at: 2.days.ago,
      report_submitted_at: 1.day.ago
    )
    latest_report = create(
      :evaluation, :completed,
      evaluation_date: 1.day.from_now,
      appointment_completed_at: 3.days.ago,
      report_submitted_at: 1.hour.ago
    )
    legacy_report = create(:evaluation, :completed, evaluation_date: 14.days.from_now)
    legacy_report.update!(appointment_completed_at: nil, report_submitted_at: nil)

    report_ids = [earlier_report.id, latest_report.id, legacy_report.id]
    ordered_ids = Evaluation.completed_sessions.where(id: report_ids).by_report_submission.ids

    assert_equal [latest_report.id, earlier_report.id, legacy_report.id], ordered_ids
  end

  test 'catalog outcome still requires both products tried and catalog recommendations' do
    evaluation = create(:evaluation)

    assert evaluation.recommendation_outcome_catalog_products?
    assert_not evaluation.update(
      status: :completed,
      appointment_completed_at: 1.hour.ago,
      report_submitted_at: Time.current,
      recommended_product_ids: [],
      products_tried: []
    )

    assert_includes evaluation.errors[:recommended_products], "can't be blank"
    assert_includes evaluation.errors[:products_tried], "can't be blank"
    assert_equal 'scheduled', evaluation.reload.status
  end

  test 'new completion rejects archived recommendations while preserving historical product trials' do
    evaluation = create(:evaluation)
    archived_product = evaluation.recommended_products.first
    archived_product.archive!
    completion = {
      status: :completed, appointment_completed_at: 1.hour.ago, report_submitted_at: Time.current
    }

    assert_not evaluation.update(completion)
    assert_includes evaluation.errors[:recommended_products], 'cannot include archived catalog products'
    assert_equal 'scheduled', evaluation.reload.status

    historical_trials = evaluation.products_tried
    active_product = create(:product)
    evaluation.update!(completion.merge(recommended_product_ids: [active_product.id]))

    assert_equal 'completed', evaluation.reload.status
    assert_equal [active_product.id], evaluation.recommended_product_ids
    assert_equal historical_trials, evaluation.products_tried
  end

  test 'archiving a previously recommended product does not prevent supplemental report notes' do
    evaluation = create(:evaluation, :completed)
    original_recommendations = evaluation.recommended_product_ids.sort
    evaluation.recommended_products.first.archive!

    evaluation.update!(post_completion_notes: 'Product availability changed after this assessment')

    assert_equal original_recommendations, evaluation.reload.recommended_product_ids.sort
    assert_equal 'Product availability changed after this assessment', evaluation.post_completion_notes
  end

  test 'outside catalog and no suitable product outcomes can complete without inventing products' do
    %w[outside_catalog no_suitable_product].each do |outcome|
      evaluation = create(:evaluation)
      scheduled_date = evaluation.evaluation_date

      evaluation.update!(
        status: :completed,
        appointment_completed_at: 1.hour.ago,
        report_submitted_at: Time.current,
        recommendation_outcome: outcome,
        recommendation_notes: 'Assessment findings and the reason for this outcome',
        recommended_product_ids: [],
        products_tried: [],
        attendees: []
      )

      evaluation.reload
      assert_equal 'completed', evaluation.status
      assert_equal outcome, evaluation.recommendation_outcome
      assert_equal 'Assessment findings and the reason for this outcome', evaluation.recommendation_notes
      assert_empty evaluation.recommended_products
      assert_empty evaluation.products_tried
      assert_empty evaluation.attendees
      assert_equal scheduled_date, evaluation.evaluation_date
    end
  end

  test 'noncatalog recommendations may retain catalog products tried during the assessment' do
    evaluation = create(:evaluation)
    tried_products = evaluation.products_tried

    evaluation.update!(
      status: :completed,
      appointment_completed_at: 1.hour.ago,
      report_submitted_at: Time.current,
      recommendation_outcome: :no_suitable_product,
      recommendation_notes: 'The catalog products tried did not meet the applicant needs',
      recommended_product_ids: []
    )

    assert_equal 'completed', evaluation.reload.status
    assert_equal tried_products, evaluation.products_tried
    assert_empty evaluation.recommended_products
  end

  test 'noncatalog outcomes require an explanation and reject contradictory catalog recommendations' do
    %w[outside_catalog no_suitable_product].each do |outcome|
      evaluation = create(:evaluation)
      completion = {
        status: :completed,
        appointment_completed_at: 1.hour.ago,
        report_submitted_at: Time.current,
        recommendation_outcome: outcome
      }

      assert_not evaluation.update(completion.merge(recommended_product_ids: [], recommendation_notes: ''))
      assert_includes evaluation.errors[:recommendation_notes], "can't be blank"
      assert_equal 'scheduled', evaluation.reload.status

      assert_not evaluation.update(completion.merge(recommendation_notes: 'Reason for the noncatalog outcome'))
      assert_includes evaluation.errors[:recommended_products], 'must be empty when the outcome does not recommend catalog products'
      assert_equal 'scheduled', evaluation.reload.status
    end
  end

  test 'outcome rejects unknown or missing values without replacing the stored catalog default' do
    evaluation = create(:evaluation)

    ['unknown', nil].each do |outcome|
      assert_not evaluation.update(recommendation_outcome: outcome)
      assert_includes evaluation.errors[:recommendation_outcome], 'is not included in the list'
      assert_equal 'catalog_products', evaluation.reload.recommendation_outcome
    end
  end

  test 'working notes can be stored without changing appointment report or product fields' do
    evaluation = create(:evaluation)
    original_record = evaluation.attributes.except('working_notes', 'updated_at')
    original_recommendations = evaluation.recommended_product_ids

    evaluation.update!(working_notes: 'Left a voicemail; call again next week')

    assert_equal 'Left a voicemail; call again next week', evaluation.reload.working_notes
    assert_equal original_record, evaluation.attributes.except('working_notes', 'updated_at')
    assert_equal original_recommendations, evaluation.recommended_product_ids
  end

  test 'working notes are editable for unfinished assignments and locked after completion' do
    %w[requested scheduled confirmed cancelled no_show rescheduled].each do |status|
      assert Evaluation.new(status: status).working_notes_editable?, status
    end

    assert_not Evaluation.new(status: :completed).working_notes_editable?
    assert_not Evaluation.new(status: nil).working_notes_editable?
  end
end
