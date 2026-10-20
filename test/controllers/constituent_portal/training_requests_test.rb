# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class TrainingRequestsTest < ActionDispatch::IntegrationTest
    setup do
      @constituent = create(:constituent)
      @application = create(:application, :approved, :with_all_proofs, user: @constituent, application_date: Date.current)
      Policy.find_or_create_by!(key: 'max_training_sessions').update!(value: 3)
      sign_in_for_integration_test(@constituent)
    end

    test 'own training request persists once with an actor-specific audit' do
      assert_difference -> { Event.where(auditable: @application, action: 'training_session_requested').count }, 1 do
        post request_training_constituent_portal_application_path(@application)
      end
      assert_redirected_to constituent_portal_dashboard_path
      assert_not_nil @application.reload.training_requested_at
      assert_equal I18n.t('applications.training_requests.messages.submitted'), flash[:notice]
      assert_equal @constituent.id, Event.find_by!(auditable: @application, action: 'training_session_requested').user_id

      assert_no_difference -> { Event.where(auditable: @application, action: 'training_session_requested').count } do
        post request_training_constituent_portal_application_path(@application)
      end
      assert_equal I18n.t('applications.training_requests.messages.duplicate_pending'), flash[:alert]
    end

    test 'unapproved applications and exhausted quota cannot start another request' do
      @application.update!(status: :in_progress)
      assert_no_changes -> { @application.reload.training_requested_at } do
        post request_training_constituent_portal_application_path(@application)
      end
      assert_equal I18n.t('applications.training_requests.messages.ineligible'), flash[:alert]

      @application.update!(status: :approved)
      create_list(:training_session, 3, :completed, application: @application)
      assert_no_changes -> { @application.reload.training_requested_at } do
        post request_training_constituent_portal_application_path(@application)
      end
      assert_equal I18n.t('applications.training_requests.messages.quota_exhausted'), flash[:alert]
    end

    test 'current managing guardian requests covered training while another related guardian and a former manager cannot' do
      manager = create(:constituent, locale: 'es')
      other_guardian = create(:constituent)
      [manager, other_guardian].each do |guardian|
        create(:guardian_relationship, guardian_user: guardian, dependent_user: @constituent)
      end
      trainer = create(:trainer)
      @application.update!(managing_guardian: manager, assigned_trainer: trainer)
      create(:training_session, :completed, application: @application, trainer: trainer)

      sign_in_for_integration_test(other_guardian)
      post request_training_constituent_portal_application_path(@application)
      assert_response :not_found
      assert_nil @application.reload.training_requested_at

      sign_in_for_integration_test(manager)
      post request_training_constituent_portal_application_path(@application, locale: 'es')
      assert_redirected_to constituent_portal_dashboard_path
      assert_not_nil @application.reload.training_requested_at
      assert_equal I18n.t('applications.training_requests.messages.submitted_covered', locale: 'es'), flash[:notice]

      @application.update!(managing_guardian: other_guardian)
      requested_at = @application.reload.training_requested_at
      post request_training_constituent_portal_application_path(@application)
      assert_response :not_found
      assert_equal requested_at, @application.reload.training_requested_at
    end
  end
end
