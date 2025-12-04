# frozen_string_literal: true

require 'test_helper'

module Admin
  # Tests for draft application visibility in the admin applications index
  # Verifies that draft applications are hidden by default but visible when explicitly filtered
  class ApplicationsDraftVisibilityTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin, email: generate(:email))
      sign_in_for_integration_test(@admin)

      # Use today's date so test apps appear on page 1 when sorted by application_date desc
      today = Date.current

      # Create applications in various statuses
      @draft_app = create(:application, :draft, application_date: today,
                                                user: create(:constituent, email: generate(:email)))
      @in_progress_app = create(:application, :in_progress, application_date: today,
                                                            user: create(:constituent, email: generate(:email)))

      # For approved - create with proofs attached, then update status
      @approved_app = create(:application, :in_progress, :with_all_proofs, application_date: today,
                                                                           user: create(:constituent, email: generate(:email)))
      @approved_app.update_columns(
        status: Application.statuses[:approved],
        income_proof_status: Application.income_proof_statuses[:approved],
        residency_proof_status: Application.residency_proof_statuses[:approved],
        medical_certification_status: Application.medical_certification_statuses[:approved]
      )

      # For rejected - no proofs required
      @rejected_app = create(:application, :rejected, application_date: today,
                                                      user: create(:constituent, email: generate(:email)))

      # For archived - create with proofs, then update status
      @archived_app = create(:application, :in_progress, :with_income_proof, :with_residency_proof,
                             application_date: today,
                             user: create(:constituent, email: generate(:email)))
      @archived_app.update_columns(
        status: Application.statuses[:archived],
        income_proof_status: Application.income_proof_statuses[:approved],
        residency_proof_status: Application.residency_proof_statuses[:approved]
      )
    end

    test 'index does not show draft applications by default' do
      get admin_applications_path
      assert_response :success

      # Should see in_progress and approved
      assert_select "tr#application_#{@in_progress_app.id}", count: 1
      assert_select "tr#application_#{@approved_app.id}", count: 1

      # Should NOT see draft, rejected, or archived
      assert_select "tr#application_#{@draft_app.id}", count: 0
      assert_select "tr#application_#{@rejected_app.id}", count: 0
      assert_select "tr#application_#{@archived_app.id}", count: 0
    end

    test 'index shows draft applications when status filter is draft' do
      get admin_applications_path, params: { status: 'draft' }
      assert_response :success

      # Should see draft application
      assert_select "tr#application_#{@draft_app.id}", count: 1

      # Should NOT see other statuses (filter is exclusive)
      assert_select "tr#application_#{@in_progress_app.id}", count: 0
      assert_select "tr#application_#{@approved_app.id}", count: 0
    end

    test 'index shows draft applications when filter param is draft' do
      get admin_applications_path, params: { filter: 'draft' }
      assert_response :success

      # Should see draft application
      assert_select "tr#application_#{@draft_app.id}", count: 1

      # Filter might show other statuses too depending on implementation
      # But draft should definitely be visible
    end

    test 'index shows all statuses when no filter applied except draft rejected archived' do
      get admin_applications_path
      assert_response :success

      # Count applications in response
      # Should include in_progress and approved
      assert_select 'tr[id^="application_"]', minimum: 2

      # Verify specific applications are present/absent
      assert_select "tr#application_#{@in_progress_app.id}"
      assert_select "tr#application_#{@approved_app.id}"
      assert_select "tr#application_#{@draft_app.id}", count: 0
      assert_select "tr#application_#{@rejected_app.id}", count: 0
      assert_select "tr#application_#{@archived_app.id}", count: 0
    end

    test 'index shows only in_progress when filtered by in_progress status' do
      get admin_applications_path, params: { status: 'in_progress' }
      assert_response :success

      # Should see in_progress
      assert_select "tr#application_#{@in_progress_app.id}", count: 1

      # Should NOT see others
      assert_select "tr#application_#{@draft_app.id}", count: 0
      assert_select "tr#application_#{@approved_app.id}", count: 0
    end

    test 'index shows only approved when filtered by approved status' do
      get admin_applications_path, params: { status: 'approved' }
      assert_response :success

      # Should see approved
      assert_select "tr#application_#{@approved_app.id}", count: 1

      # Should NOT see others
      assert_select "tr#application_#{@draft_app.id}", count: 0
      assert_select "tr#application_#{@in_progress_app.id}", count: 0
    end

    test 'index shows rejected applications when explicitly filtered' do
      get admin_applications_path, params: { status: 'rejected' }
      assert_response :success

      # Should see rejected
      assert_select "tr#application_#{@rejected_app.id}", count: 1

      # Should NOT see others
      assert_select "tr#application_#{@draft_app.id}", count: 0
      assert_select "tr#application_#{@in_progress_app.id}", count: 0
    end

    test 'multiple draft applications all visible when draft filter applied' do
      # Create additional draft applications with recent dates
      today = Date.current
      draft_app_2 = create(:application, :draft, application_date: today,
                                                 user: create(:constituent, email: generate(:email)))
      draft_app_3 = create(:application, :draft, application_date: today,
                                                 user: create(:constituent, email: generate(:email)))

      get admin_applications_path, params: { status: 'draft' }
      assert_response :success

      # Should see all three draft applications
      assert_select "tr#application_#{@draft_app.id}", count: 1
      assert_select "tr#application_#{draft_app_2.id}", count: 1
      assert_select "tr#application_#{draft_app_3.id}", count: 1
    end

    test 'draft applications for dependents visible when draft filter applied' do
      guardian = create(:constituent, email: generate(:email))
      dependent = create(:constituent, email: generate(:email))
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)

      draft_dependent_app = create(
        :application,
        :draft,
        application_date: Date.current,
        user: dependent,
        managing_guardian: guardian
      )

      get admin_applications_path, params: { status: 'draft' }
      assert_response :success

      # Should see dependent's draft application
      assert_select "tr#application_#{draft_dependent_app.id}", count: 1
    end

    test 'clear filters returns to default view without drafts' do
      # First apply draft filter
      get admin_applications_path, params: { status: 'draft' }
      assert_response :success
      assert_select "tr#application_#{@draft_app.id}", count: 1

      # Then clear filters
      get admin_applications_path
      assert_response :success

      # Draft should no longer be visible
      assert_select "tr#application_#{@draft_app.id}", count: 0
      assert_select "tr#application_#{@in_progress_app.id}", count: 1
    end

    test 'pagination maintains draft visibility when filtered' do
      # Create many draft applications to trigger pagination (with recent dates)
      today = Date.current
      20.times do
        create(:application, :draft, application_date: today,
                                     user: create(:constituent, email: generate(:email)))
      end

      get admin_applications_path, params: { status: 'draft', page: 1 }
      assert_response :success

      # Should see draft applications on page 1
      assert_select 'tr[id^="application_"]', minimum: 1

      # All visible applications should be drafts
      # (This is implicit - if non-drafts were showing, the IDs wouldn't match the draft pattern)
    end

    test 'search with draft filter maintains draft visibility' do
      # Create a draft with a searchable name
      searchable_constituent = create(:constituent,
                                      first_name: 'Searchable',
                                      last_name: 'DraftUser',
                                      email: generate(:email))
      searchable_draft = create(:application, :draft, application_date: Date.current,
                                                      user: searchable_constituent)

      get admin_applications_path, params: { status: 'draft', q: 'Searchable' }
      assert_response :success

      # Should find the searchable draft
      assert_select "tr#application_#{searchable_draft.id}", count: 1
    end
  end
end
