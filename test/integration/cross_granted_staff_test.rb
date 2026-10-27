# frozen_string_literal: true

require 'test_helper'

# A grant gives staff the other discipline: portal access, navigation, and their own assigned work.
class CrossGrantedStaffTest < ActionDispatch::IntegrationTest
  setup do
    @granted_trainer = create(:evaluator)
    create(:role_capability, user: @granted_trainer, capability: 'can_train')
    @granted_evaluator = create(:trainer)
    create(:role_capability, user: @granted_evaluator, capability: 'can_evaluate')
  end

  test 'an evaluator granted training reaches the trainer portal and sees its link' do
    sign_in_for_integration_test(@granted_trainer)

    get trainers_dashboard_path
    assert_response :success

    get edit_profile_path
    assert_select 'nav a[href=?]', trainers_dashboard_path, text: 'Training sessions'
  end

  test 'a trainer granted evaluation reaches the evaluator portal and sees its link' do
    create(:evaluation, evaluator: @granted_evaluator, status: :requested)
    sign_in_for_integration_test(@granted_evaluator)

    get evaluators_dashboard_path
    assert_response :success

    get edit_profile_path
    assert_select 'nav a[href=?]', evaluators_dashboard_path, text: 'Evaluations'
  end

  test 'staff without the grant, constituents, and inactive grantees stay out' do
    {
      'an evaluator without training' => [create(:evaluator), trainers_dashboard_path],
      'a trainer without evaluation' => [create(:trainer), evaluators_dashboard_path],
      'a constituent for trainers' => [create(:constituent), trainers_dashboard_path],
      'a constituent for evaluators' => [create(:constituent), evaluators_dashboard_path]
    }.each do |name, (user, path)|
      sign_in_for_integration_test(user)
      get path
      assert_redirected_to root_path, name
    end

    @granted_trainer.update!(status: :inactive)
    sign_in_for_integration_test(@granted_trainer)
    get trainers_dashboard_path
    assert_response :redirect
  end

  test 'administrators keep both portals and no secondary navigation links' do
    sign_in_for_integration_test(create(:admin))

    get trainers_dashboard_path
    assert_response :success
    get evaluators_dashboard_path
    assert_response :success
  end
end
