# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class CatalogEligibilityTest < ActiveSupport::TestCase
    setup do
      @evaluation = create(:evaluation, status: :scheduled)
      @product = create(:product, eligible_disability_groups: ['deafblind'])
      @application = @evaluation.application
      @application.update!(program_disability_groups: ['deaf'])
      load_seeded_email_templates('evaluator_mailer_evaluation_submission_confirmation')
    end

    test 'assigned evaluator explicitly confirms another group before recommendation validation' do
      result = SubmissionService.new(@evaluation, report(program_disability_groups: %w[deaf deafblind]), actor: @evaluation.evaluator).call
      assert result.success?, result.message
      assert_equal %w[deaf deafblind], @application.reload.program_disability_groups
      assert_equal [@product.id], @evaluation.reload.recommended_product_ids
      assert_equal 1, @application.equipment_needs.where(product: @product).sum(:remaining_quantity)
      assert Event.exists?(auditable: @application, action: 'equipment_profile_updated')
    end

    test 'out of group recommendation rolls back group changes and completed report' do
      Rails.logger.expects(:error).with("Evaluation submission failed for ID #{@evaluation.id}: ActiveRecord::RecordInvalid").once
      result = SubmissionService.new(@evaluation, report(program_disability_groups: ['speech']), actor: @evaluation.evaluator).call
      assert result.failure?
      assert_includes @evaluation.errors[:recommended_products].join, 'eligible for a confirmed application program group'
      assert_equal ['deaf'], @application.reload.program_disability_groups
      assert_equal 'scheduled', @evaluation.reload.status
      assert_empty @application.equipment_needs
    end

    test 'unassigned evaluator cannot amend the application group set' do
      result = SubmissionService.new(@evaluation, report(program_disability_groups: ['deafblind']), actor: create(:evaluator)).call
      assert result.failure?
      assert_equal ['deaf'], @application.reload.program_disability_groups
      assert_equal 'scheduled', @evaluation.reload.status
    end

    test 'draft models are rejected as trials and recommendations but discontinued trials remain valid' do
      Rails.logger.expects(:error).with("Evaluation submission failed for ID #{@evaluation.id}: ActiveRecord::RecordInvalid").once
      @product.update!(model_confirmed: false)
      result = SubmissionService.new(@evaluation, report(program_disability_groups: ['deafblind']), actor: @evaluation.evaluator).call
      assert result.failure?
      assert_includes @evaluation.errors[:products_tried].join, 'confirmed catalog products'
      @product.update!(model_confirmed: true, archived_at: Time.current)
      parameters = report(program_disability_groups: ['deafblind'], recommended_product_ids: [], recommendation_notes: 'No suitable available model.', no_suitable_product: '1')
      result = SubmissionService.new(@evaluation.reload, parameters, actor: @evaluation.evaluator).call
      assert result.success?, result.message
      assert_equal @product.id.to_s, @evaluation.reload.products_tried.sole['product_id']
    end

    test 'shipping suggestions persist only after explicit confirmation and audit omits contents' do
      address = { shipping_address_1: '71 Private Street', shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201' }
      result = SubmissionService.new(@evaluation, report(**address, program_disability_groups: ['deafblind'], shipping_confirmed: '1'), actor: @evaluation.evaluator).call
      assert result.success?, result.message
      assert_equal '71 Private Street', @application.reload.shipping_address_1
      event = Event.find_by!(auditable: @application, action: 'equipment_profile_updated')
      assert_includes event.field_changes.keys, 'shipping_address_1'
      assert_equal @evaluation.id, event.metadata['evaluation_id']
      assert_not_includes event.field_changes.keys, 'lock_version'
      assert_not_includes event.metadata.to_json, '71 Private Street'
      raw = Application.connection.select_value("SELECT shipping_address_1 FROM applications WHERE id = #{@application.id}")
      assert_not_includes raw, '71 Private Street'
    end

    test 'unconfirmed shipping suggestions leave the saved destination unchanged' do
      original = @application.shipping_snapshot
      result = SubmissionService.new(@evaluation, report(shipping_address_1: 'Unconfirmed suggestion', program_disability_groups: ['deafblind']), actor: @evaluation.evaluator).call

      assert result.success?, result.message
      assert_equal original, @application.reload.shipping_snapshot
      event = @application.events.find_by!(action: 'equipment_profile_updated')
      assert_equal ['program_disability_groups'], event.field_changes.keys
      assert_not_includes event.metadata.to_json, 'Unconfirmed suggestion'
    end

    test 'confirmed incomplete shipping rolls back both profile and report without a success audit' do
      original = @application.attributes
      Rails.logger.expects(:error).with("Evaluation submission failed for ID #{@evaluation.id}: ActiveRecord::RecordInvalid").once
      parameters = report(shipping_confirmed: '1', shipping_address_1: 'Incomplete destination', program_disability_groups: ['deafblind'])

      assert_no_difference('Event.count') do
        result = SubmissionService.new(@evaluation, parameters, actor: @evaluation.evaluator).call
        assert result.failure?
        assert_includes result.message, 'Complete the confirmed shipping destination'
      end

      assert_equal original, @application.reload.attributes
      assert_equal 'scheduled', @evaluation.reload.status
      assert_empty @application.equipment_needs
    end

    private

    def report(**changes)
      ActionController::Parameters.new(evaluation: {
        appointment_completed_at: 1.hour.ago, location: 'Library', notes: 'Actual assessment notes',
        no_suitable_product: '0', recommended_product_ids: [@product.id.to_s],
        products_tried_inputs: { @product.id.to_s => { selected: '1', reaction: 'Neutral' } }
      }.merge(changes))
    end
  end
end
