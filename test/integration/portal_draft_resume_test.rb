# frozen_string_literal: true

require 'test_helper'

class PortalDraftResumeTest < ActionDispatch::IntegrationTest
  setup do
    @guardian = create(:constituent, :with_disabilities)
    @other_guardian = create(:constituent, :with_disabilities)
    @dependent = create(:constituent, :with_disabilities)
  end

  test 'a guardian cannot resume a co-guardian managed draft' do
    draft = create(:application, :draft, user: @dependent, managing_guardian: @other_guardian)
    assert_wrong_draft_is_not_resumed(draft, actor: @guardian)
  end

  test 'a guardian cannot resume the dependent own unmanaged draft' do
    # The applicant started this draft before either guardian relationship existed.
    draft = create(:application, :draft, user: @dependent)
    assert_nil draft.managing_guardian_id
    assert_wrong_draft_is_not_resumed(draft, actor: @guardian)
  end

  test 'a dependent signing in cannot resume a guardian managed draft' do
    draft = create(:application, :draft, user: @dependent, managing_guardian: @guardian)
    assert_wrong_draft_is_not_resumed(draft, actor: @dependent)
  end

  test 'GET new and both writers continue the same newest unmanaged draft' do
    older = create(:application, :draft, user: @guardian, created_at: 2.days.ago, household_size: 2)
    newer = create(:application, :draft, user: @guardian, created_at: 1.day.ago, household_size: 3)
    sign_in_for_integration_test(@guardian)

    get new_constituent_portal_application_path
    assert_redirected_to edit_constituent_portal_application_path(newer)

    assert_no_difference 'Application.count' do
      patch autosave_field_constituent_portal_applications_path, params: autosave_params.merge(field_value: '4'), as: :json
      assert_response :success
      assert_equal newer.id, response.parsed_body['applicationId']

      post constituent_portal_applications_path, params: form_params(@guardian).merge(save_draft: 'Save Application')
      assert_redirected_to constituent_portal_application_path(newer)
    end
    assert_equal 7, newer.reload.household_size
    assert_equal 2, older.reload.household_size
  end

  private

  def assert_wrong_draft_is_not_resumed(draft, actor:)
    [@guardian, @other_guardian].each do |guardian|
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @dependent)
    end
    before = draft.reload.attributes
    assert_nil Application.resumable_portal_draft([draft], actor_id: actor.id)
    sign_in_for_integration_test(actor)
    applicant_params = actor == @dependent ? {} : { user_id: @dependent.id }

    get new_constituent_portal_application_path, params: applicant_params
    assert_response :success

    assert_no_difference ['Application.count', 'Event.count'] do
      patch autosave_field_constituent_portal_applications_path,
            params: autosave_params.merge(applicant_params), as: :json
      assert_response :unprocessable_content
      assert_includes response.parsed_body.dig('errors', 'base').join, 'already have an active application'

      post constituent_portal_applications_path,
           params: form_params(@dependent).merge(submit_application: 'Submit Application')
      assert_response :unprocessable_content
      assert_includes response.body, 'already have an active application'
    end
    assert_equal before, draft.reload.attributes
  end

  def autosave_params
    { field_name: 'application[household_size]', field_value: '7',
      autosave_context: SecureRandom.uuid, autosave_revision: 1 }
  end

  def form_params(applicant)
    { application: { user_id: applicant.id, annual_income: '50000', household_size: 7,
                     vision_disability: true, terms_accepted: true, information_verified: true,
                     medical_release_authorized: true,
                     medical_provider_attributes: { name: 'Test Provider', phone: '2025550123', email: 'provider@example.org' } } }
  end
end
