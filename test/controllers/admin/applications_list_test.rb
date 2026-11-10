# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsListTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'review is the default and all applications retains approved and draft records' do
      review = create(:application, :in_progress)
      draft = create(:application, :draft)
      approved = create(:application, :approved, :with_all_proofs)

      get admin_applications_path
      assert_response :success
      assert_select "tr#application_#{review.id}"
      assert_select "tr#application_#{draft.id}", count: 0
      assert_select "tr#application_#{approved.id}", count: 0

      get admin_applications_path(view: 'all')
      assert_response :success
      [review, draft, approved].each { |application| assert_select "tr#application_#{application.id}" }
    end

    test 'review and all show the current status duration and status header sorts that duration' do
      older = create(:application, :in_progress, user: create(:constituent, last_name: 'StatusClock'), created_at: 60.days.ago)
      newer = create(:application, :in_progress, user: create(:constituent, last_name: 'StatusClock'), created_at: 70.days.ago)
      older.transition_status!(:awaiting_proof, actor: @admin)
      newer.transition_status!(:awaiting_proof, actor: @admin)
      older.status_changes.last.update!(changed_at: 31.days.ago)
      newer.status_changes.last.update!(changed_at: 4.days.ago)

      %w[review all].each do |view|
        get admin_applications_path(view: view, q: 'StatusClock', status: 'awaiting_proof', sort: 'status', direction: 'desc')
        assert_response :success
        assert_equal [older.id, newer.id], listed_ids
        assert_select "tr#application_#{older.id}", text: /31 days/
        assert_select 'th[aria-sort="descending"]', text: /Status/

        get admin_applications_path(view: view, q: 'StatusClock', status: 'awaiting_proof', sort: 'status', direction: 'asc')
        assert_equal [newer.id, older.id], listed_ids
      end
    end

    test 'sorting applies before pagination and header links keep the current filters' do
      newest = create(:application, :in_progress, user: create(:constituent, last_name: 'SortCohort'), created_at: 1.hour.ago)
      # A full first page proves sorting changes the whole relation, not just its visible rows.
      20.times { create(:application, :in_progress, user: create(:constituent, last_name: 'SortCohort'), created_at: 1.day.ago) }
      oldest = create(:application, :in_progress, user: create(:constituent, last_name: 'SortCohort'), created_at: 2.days.ago)

      get admin_applications_path(view: 'review', q: 'SortCohort', status: 'in_progress', sort: 'created_at', direction: 'asc')
      assert_response :success
      assert_equal oldest.id, listed_ids.first
      assert_not_includes listed_ids, newest.id

      header_link = css_select('th a').find { |link| link.text.include?('Applicant') }
      query = Rack::Utils.parse_nested_query(URI.parse(header_link['href']).query)
      assert_equal 'review', query['view']
      assert_equal 'SortCohort', query['q']
      assert_equal 'in_progress', query['status']
      assert_equal 'applicant', query['sort']
      assert_nil query['page']
    end

    test 'next action is the same label used for sorting' do
      open_application = create(:application, :in_progress, user: create(:constituent, last_name: 'NextActionCohort'))
      proof_review = create(:application, :in_progress, :with_residency_proof, user: create(:constituent, last_name: 'NextActionCohort'))

      get admin_applications_path(view: 'review', q: 'NextActionCohort', sort: 'next_action', direction: 'asc')
      assert_response :success
      assert_equal [open_application.id, proof_review.id], listed_ids
      assert_select "tr#application_#{open_application.id} a", text: 'Open application'
      assert_select "tr#application_#{proof_review.id} a", text: 'Review proof'
      assert_select "tr#application_#{open_application.id} a[href=?]", admin_application_path(open_application), text: 'Open application'
      assert_select "tr#application_#{proof_review.id} a[href=?]", admin_application_path(proof_review, anchor: 'attachments-section'), text: 'Review proof'
    end

    test 'approved during uses approval time rather than creation and preserves older backlog by default' do
      old = approved_application(approved_at: 150.days.ago, created_at: 200.days.ago)
      recent = approved_application(approved_at: 10.days.ago, created_at: 300.days.ago)

      get admin_applications_path(view: 'pipeline', q: 'PipelineListCohort')
      assert_response :success
      assert_select "tr#application_#{old.id}"
      assert_select "tr#application_#{recent.id}"

      get admin_applications_path(view: 'pipeline', q: 'PipelineListCohort', date_range: 'last_30')
      assert_response :success
      assert_select "tr#application_#{old.id}", count: 0
      assert_select "tr#application_#{recent.id}"

      get admin_applications_path(view: 'pipeline', q: 'PipelineListCohort', page: 'invalid')
      assert_response :success
      assert_select "tr#application_#{old.id}"
    end

    test 'equipment view contains no voucher cards and voucher view exposes expired unused value' do
      equipment = approved_application(approved_at: 15.days.ago)
      voucher_application = approved_application(approved_at: 250.days.ago, fulfillment_type: :voucher)
      create(:voucher, :expired, application: voucher_application, remaining_value: 125)

      get admin_applications_path(view: 'pipeline', q: 'PipelineListCohort', group: 'equipment')
      assert_response :success
      assert_select "tr#application_#{equipment.id}"
      assert_select '[data-pipeline-stage="voucher_expired"]', count: 0

      get admin_applications_path(view: 'pipeline', q: 'PipelineListCohort', group: 'voucher', stage: 'voucher_expired')
      assert_response :success
      assert_select "tr#application_#{voucher_application.id}", text: /125/
    end

    test 'changing filters in the training queue keeps its representation and bulk session loading' do
      applications = 2.times.map do
        application = create(:application, :approved, :with_all_proofs, user: create(:constituent, last_name: 'PendingTrainingCohort'))
        application.update!(training_requested_at: 1.hour.ago)
        application
      end
      session_loads = []
      recorder = ->(*, payload) { session_loads << payload[:sql] if payload[:name] == 'TrainingSession Load' }
      ActiveSupport::Notifications.subscribed(recorder, 'sql.active_record') do
        get admin_applications_path(view: 'all', filter: 'training_requests', status: '', q: 'PendingTrainingCohort', date_range: 'last_30')
      end

      assert_response :success
      assert_select '[data-testid="training-requests-queue"]'
      applications.each { |application| assert_select "#training_request_row_#{application.id}" }
      assert_equal 1, session_loads.length
      assert_select 'input[name="filter"][value="training_requests"]'
    end

    private

    def listed_ids
      css_select('tr.application-row').map { |row| row['id'].delete_prefix('application_').to_i }
    end

    def approved_application(approved_at:, created_at: 1.year.ago, fulfillment_type: :equipment)
      application = create(:application, :approved, :with_all_proofs, user: create(:constituent, last_name: 'PipelineListCohort'), created_at: created_at)
      application.update!(fulfillment_type: fulfillment_type)
      application.status_changes.create!(from_status: 'in_progress', to_status: 'approved', changed_at: approved_at,
                                         user: @admin, change_type: :status)
      application
    end
  end
end
