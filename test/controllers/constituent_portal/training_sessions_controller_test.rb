# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class TrainingSessionsControllerTest < ActionDispatch::IntegrationTest
    PRIVATE_TEXT = 'PRIVATE SESSION OBSERVATIONS 9421'

    setup do
      @user = create(:constituent)
      @trainer = create(:trainer)
      @application = create(:application, :approved, :with_all_proofs, user: @user)
      @demo = create(:product, :archived, name: 'Demo captions device')
      @session = completed_session(@application)
      sign_in_for_integration_test(@user)
    end

    test 'history includes own and currently managed applications including historical reports and excludes unrelated and unresolved sessions' do
      dependent, managed = managed_application(@user)
      managed_session = completed_session(managed)
      historical = create(:application, user: @user, status: :archived)
      historical_session = completed_session(historical)
      stranger_session = completed_session(create(:application, :approved))
      open_session = create(:training_session, :scheduled, application: @application, trainer: @trainer)

      get constituent_portal_training_sessions_path

      assert_response :success
      [@session, managed_session, historical_session].each do |session|
        assert_select 'a[href=?]', constituent_portal_training_session_path(session)
      end
      [stranger_session, open_session].each do |session|
        assert_select 'a[href=?]', constituent_portal_training_session_path(session), count: 0
      end
      assert_includes response.body, @user.full_name
      assert_includes response.body, dependent.full_name
      assert_not_includes response.body, PRIVATE_TEXT
    end

    test 'completed summary keeps its authored language and demo guidance without claiming device ownership or revealing private fields' do
      create(:product_resource, product: @demo, title: 'Captions practice guide', locale: 'en')
      create(:product_resource, product: @demo, title: 'Guía de subtítulos', locale: 'es')
      assert_empty @user.products

      get constituent_portal_training_session_path(@session)

      assert_response :success
      assert_select 'div[lang=es]', text: /Practicamos los subtítulos/
      assert_includes response.body, 'Written in Spanish'
      assert_select 'a[target="_blank"][rel="noopener noreferrer"]', text: 'Captions practice guide'
      assert_select 'a', text: 'Guía de subtítulos'
      assert_includes response.body, 'does not establish ownership'
      assert_not_includes response.body, PRIVATE_TEXT
      assert_not_includes response.body, 'Private staff'
      assert_not_includes response.body, 'cancellation reason'
      assert_not_includes response.body, 'Report submitted'
      assert_not_includes response.body, 'admin/applications'

      get constituent_portal_product_path(@demo)
      assert_response :not_found
    end

    test 'a managing guardian reads the authorized summary while related guardians and managed applicants cannot bypass the application boundary' do
      dependent, application = managed_application(@user)
      session = completed_session(application)
      get constituent_portal_training_session_path(session)
      assert_response :success
      assert_includes response.body, dependent.full_name
      assert_not_includes response.body, PRIVATE_TEXT

      other_guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: other_guardian, dependent_user: dependent)
      sign_in_for_integration_test(other_guardian)
      get constituent_portal_training_session_path(session)
      assert_response :not_found

      sign_in_for_integration_test(dependent)
      get constituent_portal_training_session_path(session)
      assert_response :not_found

      application.update!(managing_guardian: other_guardian)
      sign_in_for_integration_test(@user)
      get constituent_portal_training_session_path(session)
      assert_response :not_found
      get constituent_portal_training_sessions_path
      assert_select 'a[href=?]', constituent_portal_training_session_path(session), count: 0
    end

    test 'only completed sessions are readable and arbitrary ids do not expose another applicant report' do
      open_session = create(:training_session, :scheduled, application: @application, trainer: @trainer)
      unrelated = completed_session(create(:application, :approved))
      [open_session, unrelated].each do |session|
        get constituent_portal_training_session_path(session)
        assert_response :not_found
        assert_not_includes response.body, PRIVATE_TEXT
      end
    end

    test 'history has a translated empty state for a constituent with no reports' do
      sign_in_for_integration_test(create(:constituent, locale: 'es'))
      get constituent_portal_training_sessions_path(locale: 'es')
      assert_response :success
      assert_includes response.body, 'Todavía no hay informes de capacitación completados.'
      assert_select 'article', count: 0
    end

    private

    def completed_session(application)
      create(:training_session, :completed, application: application, trainer: @trainer, product_trained_on: @demo,
                                            internal_notes: PRIVATE_TEXT, constituent_summary: 'Practicamos los subtítulos y los contactos.',
                                            summary_locale: 'es', reschedule_reason: PRIVATE_TEXT,
                                            cancellation_reason: PRIVATE_TEXT, no_show_notes: PRIVATE_TEXT)
    end

    def managed_application(guardian)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
      [dependent, create(:application, :approved, :with_all_proofs, user: dependent, managing_guardian: guardian)]
    end
  end
end
