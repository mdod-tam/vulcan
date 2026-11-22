# frozen_string_literal: true

require 'test_helper'

module Admin
  class EquipmentNeedsControllerTest < ActionDispatch::IntegrationTest
    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @application = create(:application, :approved, :with_all_proofs)
      @evaluation = create(:evaluation, :completed, application: @application)
      EquipmentNeeds::Writer.initialize_from!(@evaluation, actor: @admin)
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
    end

    test 'needs editor shows original recommendations and current quantities' do
      get edit_admin_application_equipment_needs_path(@application)

      assert_response :success
      assert_select 'h2', text: 'Original assessment recommendation'
      assert_select 'main', count: 1
      assert_select 'main main', count: 0
      assert_select 'input[name="equipment_needs[rows][][remaining_quantity]"][value="1"]', count: @application.equipment_needs.count + 1
      assert_select 'input[name="equipment_needs[expected_initialized_at]"]', value: @application.reload.equipment_needs_initialized_at.iso8601(6)
      assert_select 'input[name="equipment_needs[expected_profile_version]"]', value: @application.equipment_profile_version
      assert_select '#equipment_needs_reason[aria-describedby=equipment-needs-reason-help]'
      assert_select '#equipment-needs-reason-help', text: 'Explain what changed or why no new devices are needed.'
      assert_select '#purchasing-needs-history[open]' do
        assert_select 'p', text: /Purchasing needs created — #{Regexp.escape(@admin.full_name)}/
        assert_select 'time[datetime]'
      end
      assert_select 'a[href=?]', admin_application_path(@application, anchor: 'equipment'), text: 'Back to Application'
      assert_operator @application.equipment_needs.count, :>=, 2
      %w[id lock_version product_id].each do |attribute|
        assert_select 'input[type=hidden][name=?][id]', "equipment_needs[rows][][#{attribute}]", count: 0
      end
      form_ids = css_select('form[aria-describedby=equipment-needs-help] [id]').pluck('id')
      assert_equal form_ids.uniq, form_ids
    end

    test 'saving returns to the same equipment tab and filters' do
      parameters = submission
      parameters[:return_context] = { tab: 'needs_ordering', product_id: @evaluation.recommended_product_ids.first }
      parameters[:equipment_needs][:rows].each { |row| row['remaining_quantity'] = 0 }
      parameters[:equipment_needs][:profile] = { shipping_care_of: '', shipping_address_2: '' }

      assert_no_difference -> { @application.events.where(action: 'equipment_profile_updated').count } do
        patch admin_application_equipment_needs_path(@application), params: parameters
      end

      assert_redirected_to admin_equipment_index_path(parameters[:return_context])
      assert_empty @application.equipment_needs.remaining
    end

    test 'invalid submission retains quantities, chosen new model, reason, versions, and return context' do
      product = create(:product)
      original_shipping = @application.shipping_snapshot
      parameters = submission
      parameters[:equipment_needs][:rows].first['remaining_quantity'] = '2'
      parameters[:equipment_needs][:rows] << { product_id: product.id, remaining_quantity: '0' }
      parameters[:equipment_needs][:profile] = EquipmentShipping::FIELDS.index_with { '' }
      parameters[:return_context] = { tab: 'needs_ordering', product_id: product.id }

      assert_no_difference('Event.count') { patch admin_application_equipment_needs_path(@application), params: parameters }

      assert_response :unprocessable_entity
      assert_select '#equipment-needs-errors[role=alert][tabindex="-1"][data-controller=error-summary]'
      assert_select '#equipment-needs-errors li', text: /at least one device/
      assert_select '#equipment-needs-errors a[href=?]', edit_admin_application_equipment_needs_path(@application, return_context: parameters[:return_context]),
                    text: 'Review latest purchasing needs'
      assert_select '#equipment-needs-errors p', text: 'Opening the latest purchasing needs discards your unsaved changes.'
      assert_select '[role="alert"]', text: /at least one device/
      assert_select 'input[name="equipment_needs[rows][][remaining_quantity]"][value="2"]'
      assert_select 'select option[selected][value=?]', product.id.to_s
      assert_select 'input[name="equipment_needs[reason]"][value="Changed purchasing needs"]'
      assert_select 'input[name="return_context[product_id]"][value=?]', product.id.to_s
      EquipmentShipping::FIELDS.each { |field| assert_select 'input[name=?][value=""]', "equipment_needs[profile][#{field}]" }
      assert_equal original_shipping, @application.reload.shipping_snapshot
      assert_equal [1], @application.equipment_needs.distinct.pluck(:remaining_quantity)
      patch admin_application_equipment_needs_path(@application), params: parameters
      assert_response :unprocessable_content
      EquipmentShipping::FIELDS.each { |field| assert_select 'input[name=?][value=""]', "equipment_needs[profile][#{field}]" }
      parameters[:equipment_needs][:rows].last[:remaining_quantity] = '1'
      patch admin_application_equipment_needs_path(@application), params: parameters
      assert_response :redirect
      assert @application.reload.shipping_snapshot.values.all?(&:blank?)
    end

    test 'constituents cannot view or update purchasing needs' do
      sign_in_for_integration_test(@application.user)

      get edit_admin_application_equipment_needs_path(@application)
      assert_redirected_to root_path
      assert_no_difference('Event.count') { patch admin_application_equipment_needs_path(@application), params: submission }
      assert_redirected_to root_path
    end

    test 'stale profile review cannot overwrite another admin or change purchasing quantities' do
      parameters = submission
      reviewed_version = parameters[:equipment_needs][:expected_profile_version]
      parameters[:equipment_needs][:profile] = { program_disability_groups: ['speech'], shipping_address_1: 'Stale address' }
      parameters[:equipment_needs][:rows].each { |row| row['remaining_quantity'] = 2 }
      @application.update!(shipping_address_1: 'New address from another admin')
      current_profile = @application.reload.attributes
      current_needs = @application.equipment_needs.order(:id).pluck(:remaining_quantity, :lock_version)

      2.times do
        assert_no_difference('Event.count') { patch admin_application_equipment_needs_path(@application), params: parameters }

        assert_response :unprocessable_content
        assert_select '[role="alert"]', text: /Application details changed/
        assert_select 'input[name="equipment_needs[expected_profile_version]"][value=?]', reviewed_version
        assert_select 'input[name="equipment_needs[profile][shipping_address_1]"][value="Stale address"]'
        assert_equal current_profile, @application.reload.attributes
        assert_equal current_needs, @application.equipment_needs.order(:id).pluck(:remaining_quantity, :lock_version)
      end

      get edit_admin_application_equipment_needs_path(@application)
      assert_select 'input[name="equipment_needs[expected_profile_version]"][value=?]', @application.equipment_profile_version
      assert_select 'input[name="equipment_needs[profile][shipping_address_1]"][value="New address from another admin"]'
    end

    test 'admin can save an unfinished shipping draft with field changes and a reason in history' do
      parameters = submission
      parameters[:equipment_needs][:profile] = EquipmentShipping::FIELDS.index_with { '' }.merge('shipping_address_1' => 'Draft shipping street')

      patch admin_application_equipment_needs_path(@application), params: parameters

      assert_response :redirect
      assert_not @application.reload.shipping_ready?
      event = @application.events.find_by!(action: 'equipment_profile_updated')
      assert_equal @admin.id, event.user_id
      assert_equal 'Changed purchasing needs', event.metadata['reason']
      assert_includes event.field_changes.keys, 'shipping_address_1'
      assert_not_includes event.metadata.to_json, 'Draft shipping street'
      assert_not_includes event.field_changes.keys, 'lock_version'
      get edit_admin_application_equipment_needs_path(@application)
      assert_select '#purchasing-needs-history', text: /Shipping address or device setup updated/
    end

    test 'a model archived before save stays selected on its failed form so staff can choose a replacement' do
      product = create(:product, :archived)
      parameters = submission
      parameters[:equipment_needs][:rows] << { product_id: product.id, remaining_quantity: '1' }

      patch admin_application_equipment_needs_path(@application), params: parameters

      assert_response :unprocessable_entity
      assert_select '[role="alert"]', text: /available catalog product/
      assert_select 'select option[selected][value=?]', product.id.to_s
      assert_not @application.equipment_needs.exists?(product: product)
    end

    test 'archived application history stays readable and has no purchasing needs edit link' do
      item = create(:equipment_item, application: @application, source_evaluation: @evaluation, tracking_number: 'Recorded device tracking')
      @application.transition_status!(:archived, actor: @admin)

      get admin_application_path(@application)

      assert_response :success
      assert_select '#equipment h3', text: 'Original assessment recommendation'
      assert_select "#equipment-item-#{item.id}", text: /Recorded device tracking/
      assert_select 'a', text: 'Edit equipment needs', count: 0
    end

    test 'empty initialization keeps its original report visible after a later catalog report' do
      application = create(:application, :approved, :with_all_proofs)
      original = build(:evaluation, :completed, application: application, report_submitted_at: 2.hours.ago,
                                                recommendation_outcome: :no_suitable_product,
                                                recommendation_notes: 'Original assessment found no suitable catalog product.')
      original.recommended_products = []
      original.products_tried = []
      original.save!
      EquipmentNeeds::Writer.initialize_from!(original, actor: @admin)
      marker = application.reload.equipment_needs_initialized_at
      later = create(:evaluation, :completed, application: application)

      [admin_application_path(application), edit_admin_application_equipment_needs_path(application)].each do |path|
        get path

        assert_response :success
        assert_select 'section[aria-labelledby=original-recommendation-title]' do
          assert_select 'p', text: 'No suitable product'
          assert_select 'p', text: original.recommendation_notes
          assert_select 'a[href=?]', evaluators_evaluation_path(original), count: 1
          assert_select 'a[href=?]', evaluators_evaluation_path(later), count: 0
          assert_select 'li', count: 0
        end
      end

      application.transition_status!(:archived, actor: @admin)
      get admin_application_path(application)

      assert_response :success
      assert_select 'section[aria-labelledby=original-recommendation-title] a[href=?]', evaluators_evaluation_path(original)
      assert_equal marker, application.reload.equipment_needs_initialized_at
      assert_empty application.equipment_needs
    end

    private

    def submission
      {
        equipment_needs: {
          expected_initialized_at: @application.reload.equipment_needs_initialized_at.iso8601(6),
          expected_profile_version: @application.equipment_profile_version,
          reason: 'Changed purchasing needs',
          rows: @application.equipment_needs.order(:id).map { |need| need.attributes.slice('id', 'product_id', 'remaining_quantity', 'lock_version') }
        }
      }
    end
  end
end
