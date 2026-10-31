# frozen_string_literal: true

require 'test_helper'

module Admin
  # Role and capability changes answer with Turbo Streams: the refreshed row, or a confirmation dialog when
  # removing access would strand open work.
  class StaffAccessTest < ActionDispatch::IntegrationTest
    TURBO = { 'Accept' => Mime[:turbo_stream].to_s }.freeze

    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      @evaluator = create(:evaluator)
    end

    test 'granting a capability refreshes the row and badges and tells the admin' do
      assert_difference 'RoleCapability.count', 1 do
        patch update_capabilities_admin_user_path(@evaluator), params: grant('can_train'), headers: TURBO
      end

      assert_response :success
      assert_equal Mime[:turbo_stream].to_s, response.media_type
      assert_targets %W[flash #{dom_id(@evaluator, :badges)} #{dom_id(@evaluator, :access)} staff_access_dialog]
      assert_includes response.body, 'Added Can Train capability.'
      assert @evaluator.reload.assignable_trainer?
    end

    test 'a role change refreshes the row ids the page rendered before the class changed' do
      get admin_users_path(q: @evaluator.email)
      rendered_ids = response.parsed_body.css('[id]').pluck('id')

      patch update_role_admin_user_path(@evaluator), params: { role: 'Users::Trainer', operation_id: SecureRandom.uuid }, headers: TURBO

      assert_response :success
      assert_equal 'Users::Trainer', User.find(@evaluator.id).type
      targets = streams.pluck('target')
      assert_empty targets - rendered_ids
    end

    test 'the table offers each role only the controls its policy allows' do
      constituent = create(:constituent)
      vendor = create(:vendor)
      trainer = create(:trainer)
      admin_target = create(:admin)

      assert_access_cell(constituent) { assert_select 'input[type=checkbox]', 0 }
      assert_access_cell(vendor) { assert_select 'input[type=checkbox]', 0 }
      assert_access_cell(@evaluator) do
        assert_select 'input[data-capability=can_train]:not([disabled])'
        assert_select 'input[data-capability=can_evaluate][disabled][checked]'
      end
      assert_access_cell(trainer) { assert_select 'input[data-capability=can_evaluate]:not([disabled])' }
      assert_access_cell(admin_target) { assert_select 'input[disabled][checked]', 2 }
      assert_access_cell(@admin) { assert_select 'input', 0 }
      assert_select '#staff_access_dialog'
    end

    test 'forged and impossible requests are refused with 422 and change nothing' do
      forged = {
        'a constituent' => [create(:constituent), grant('can_train')],
        'a vendor' => [create(:vendor), grant('can_evaluate')],
        'an administrator' => [create(:admin), grant('can_train')],
        'role-provided access' => [@evaluator, grant('can_evaluate')],
        'an unknown capability' => [@evaluator, grant('can_fly')]
      }

      forged.each do |name, (user, params)|
        assert_no_difference ['RoleCapability.count', 'Event.count'] do
          patch update_capabilities_admin_user_path(user), params: params, headers: TURBO
        end
        assert_response :unprocessable_content, name
      end
      assert_no_difference 'Event.count' do
        patch update_capabilities_admin_user_path(@evaluator), params: { capability: 'can_evaluate', enabled: 'false' }, headers: TURBO
        assert_response :unprocessable_content
      end
    end

    test 'a duplicate grant reports the no-op truthfully' do
      create(:role_capability, user: @evaluator, capability: 'can_train')

      assert_no_difference 'RoleCapability.count' do
        patch update_capabilities_admin_user_path(@evaluator), params: grant('can_train'), headers: TURBO
      end

      assert_response :success
      assert_includes response.body, 'Can Train is already granted.'
    end

    test 'removing access with open work renders the confirmation dialog without writing' do
      create(:role_capability, user: @evaluator, capability: 'can_train')
      create(:training_session, trainer: @evaluator, status: :requested)
      create(:training_session, trainer: @evaluator, status: :no_show, no_show_notes: 'Did not attend')

      assert_no_difference ['RoleCapability.count', 'Event.count'] do
        patch update_capabilities_admin_user_path(@evaluator), params: revoke('can_train', 'op-1'), headers: TURBO
      end

      assert_response :success
      assert_targets %w[staff_access_dialog]
      assert_equal @evaluator.id.to_s, dialog['data-user-id']
      assert_includes dialog.text, "#{@evaluator.full_name} has 2 active training sessions. Removing training access sends them to Training needing reassignment."
      assert_equal(%w[op-1 false can_train], %w[operation_id enabled capability].map { |name| dialog.at_css("input[name=#{name}]")['value'] })
      assert_predicate dialog.at_css('input[name=confirmation]')['value'], :present?
      assert_select_dialog_form_posts_to update_capabilities_admin_user_path(@evaluator)
    end

    test 'submitting the dialog applies the change, keeps the work, and closes the dialog through a clearing stream' do
      create(:role_capability, user: @evaluator, capability: 'can_train')
      session = create(:training_session, trainer: @evaluator, status: :requested)
      patch update_capabilities_admin_user_path(@evaluator), params: revoke('can_train', 'op-2'), headers: TURBO
      token = dialog_value('confirmation')

      patch update_capabilities_admin_user_path(@evaluator), params: revoke('can_train', 'op-2').merge(confirmation: token), headers: TURBO

      assert_response :success
      assert_not @evaluator.reload.explicit_grant?('can_train')
      assert_equal @evaluator.id, session.reload.trainer_id
      assert_includes Application.needing_trainer_reassignment.ids, session.application_id
    end

    test 'changed work answers 422 with refreshed counts and keeps the dialog open' do
      create(:role_capability, user: @evaluator, capability: 'can_train')
      create(:training_session, trainer: @evaluator, status: :requested)
      patch update_capabilities_admin_user_path(@evaluator), params: revoke('can_train', 'op-3'), headers: TURBO
      token = dialog_value('confirmation')
      create(:training_session, trainer: @evaluator, status: :requested)

      patch update_capabilities_admin_user_path(@evaluator), params: revoke('can_train', 'op-3').merge(confirmation: token), headers: TURBO

      assert_response :unprocessable_content
      assert_targets %w[staff_access_dialog]
      assert_includes response.body, 'has 2 active training sessions'
      assert_includes response.body, 'Review the current work and confirm again.'
      assert @evaluator.reload.explicit_grant?('can_train')
    end

    test 'a refusal from the open dialog stays in the dialog' do
      assert_no_difference ['RoleCapability.count', 'Event.count'] do
        patch update_capabilities_admin_user_path(@evaluator), params: revoke('can_evaluate', 'op-4').merge(confirmation: 'anything'), headers: TURBO
      end

      assert_response :unprocessable_content
      assert_targets %w[staff_access_error]
      assert_includes response.body, 'comes with this role and cannot be removed.'
    end

    test 'a role change warns for each actual loss, and an unchanged role is reported' do
      trainer = create(:trainer)
      create(:training_session, trainer: trainer, status: :requested)
      create(:role_capability, user: trainer, capability: 'can_evaluate')
      create(:evaluation, evaluator: trainer, status: :requested)

      patch update_role_admin_user_path(trainer), params: { role: 'Users::Constituent', operation_id: 'op-5' }, headers: TURBO

      assert_response :success
      assert_includes response.body, 'Removing training access sends them to Training needing reassignment.'
      assert_includes response.body, 'Removing evaluation access sends them to Evaluations needing reassignment.'
      assert_equal 'Users::Trainer', trainer.reload.type

      patch update_role_admin_user_path(trainer), params: { role: 'Users::Trainer' }, headers: TURBO
      assert_includes response.body, 'already Trainer'
    end

    test 'the user page shows the target user capability history with the acting administrator' do
      patch update_capabilities_admin_user_path(@evaluator), params: grant('can_train'), headers: TURBO
      patch update_capabilities_admin_user_path(@evaluator), params: revoke('can_train'), headers: TURBO

      get admin_user_path(@evaluator)

      assert_select '#access-history-title', text: 'Access History'
      assert_select '#access-history-title ~ div table tbody tr', 2
      assert_select 'td', text: 'Capability Removed'
      assert_select 'td', text: 'Capability Granted'
      assert_select 'td', text: @admin.full_name, minimum: 2
      get admin_user_path(@admin)
      assert_select '#access-history-title', 0
    end

    test 'access loss is observed on the very next request' do
      create(:role_capability, user: @evaluator, capability: 'can_train')
      delete sign_out_path
      sign_in_for_integration_test(@evaluator)
      get trainers_dashboard_path
      assert_response :success

      sign_in_for_integration_test(@admin)
      patch update_capabilities_admin_user_path(@evaluator), params: revoke('can_train'), headers: TURBO
      sign_in_for_integration_test(@evaluator)
      get trainers_dashboard_path

      assert_redirected_to root_path
    end

    test 'the user list reads grants without a query per row' do
      create_list(:evaluator, 2).each { |user| create(:role_capability, user: user, capability: 'can_train') }
      get admin_users_path
      few = count_capability_queries { get admin_users_path }
      create_list(:evaluator, 10).each { |user| create(:role_capability, user: user, capability: 'can_train') }

      many = count_capability_queries { get admin_users_path }

      assert_equal few, many
    end

    private

    def grant(capability, operation_id = SecureRandom.uuid) = { capability: capability, enabled: 'true', operation_id: operation_id }

    def revoke(capability, operation_id = SecureRandom.uuid) = { capability: capability, enabled: 'false', operation_id: operation_id }

    def dom_id(record, prefix) = ApplicationController.helpers.access_dom_id(record, prefix)

    def assert_access_cell(user, &)
      get admin_users_path(q: user.email)
      assert_response :success
      assert_select "##{dom_id(user, :access)}", 1, &
    end

    def streams = Nokogiri::HTML5.fragment(response.body).css('turbo-stream')

    def assert_targets(expected)
      assert_equal expected.sort, streams.pluck('target').sort
    end

    def dialog = Nokogiri::HTML5.fragment(streams.first.at_css('template').inner_html).at_css('dialog')

    def dialog_value(name) = dialog.at_css("input[name=#{name}]")['value']

    def assert_select_dialog_form_posts_to(path)
      assert_equal path, dialog.at_css('form')['action']
    end

    def count_capability_queries(&)
      count = 0
      callback = ->(*, payload) { count += 1 if payload[:sql].include?('role_capabilities') && payload[:name] != 'SCHEMA' }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
      count
    end
  end
end
