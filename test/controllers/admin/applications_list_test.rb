# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsListTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
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
      assert_select "#application_#{review.id} a[href=?]", admin_user_path(review.user) do |links|
        assert_equal "View user details for #{review.user.full_name}", links.sole['aria-label']
      end

      get admin_applications_path(view: 'all')
      assert_response :success
      [review, draft, approved].each { |application| assert_select "tr#application_#{application.id}" }
    end

    test 'review uses the same compact three-notification preview as the dashboard' do
      application = create(:application, :approved)
      notifications = 4.times.map do |index|
        create(:notification, recipient: @admin, actor: @admin, notifiable: application, action: 'proof_approved',
                              metadata: { proof_type: 'id' }, created_at: index.minutes.ago)
      end
      other_recipient = create(:notification, recipient: create(:admin), actor: @admin, notifiable: application, action: 'proof_approved',
                                              metadata: { proof_type: 'id' }, created_at: Time.current)

      get admin_applications_path(view: 'review')

      assert_response :success
      assert_select '.compact-notifications .notification-row', count: 3
      notifications.first(3).each { |notification| assert_select "#notification_#{notification.id}" }
      assert_select "#notification_#{notifications.last.id}", count: 0
      assert_select "#notification_#{other_recipient.id}", count: 0
      assert_select '.compact-notifications a[href=?]', notifications_path(scope: 'all')
    end

    test 'review cards stay on review while the global trainer assignment card excludes assigned work' do
      before = Application.awaiting_trainer_assignment.count
      create(:application, :approved, training_requested_at: 1.hour.ago, fulfillment_type: :voucher)
      create(:application, :approved, training_requested_at: 1.day.ago, assigned_trainer: create(:trainer))
      scheduled = create(:application, :approved)
      create(:training_session, :scheduled, application: scheduled)
      get admin_applications_path(view: 'review')
      assert_response :success
      assert_select '#common-tasks a.summary-card-content', count: 3
      assert_select '#common-tasks a', text: /Proofs awaiting review/
      assert_select '#common-tasks a', text: /Certifications awaiting review/
      assert_select '#common-tasks a', text: /Awaiting provider signature/
      assert_select '#common-tasks article.summary-card', count: 3
      assert_select '#service-assignments', count: 0
      assert_select 'main main', count: 0
      assert_select '#main-content[tabindex="-1"]', count: 1
      assert_select 'a.skip-link[href="#main-content"]', count: 1

      get admin_applications_path(view: 'pipeline', q: 'NoSuchServiceRequest', program_group: 'speech', stage: 'needs_fulfillment')
      assert_response :success
      assert_select '#common-tasks', count: 0
      assert_select '#service-assignments', count: 0
      assert_select '#training-summary-card' do
        assert_select '.summary-card-count', text: (before + 1).to_s
        assert_select 'a[href=?][data-turbo-frame="_top"]', trainers_dashboard_path
        assert_select 'h3', text: 'Assign trainer'
        assert_select 'p', text: 'Unassigned requests across all approved applications'
      end

      get admin_applications_path(view: 'all')
      assert_select '#common-tasks, #service-assignments, #training-summary-card', count: 0
    end

    test 'certification filters expose union received and signed with fresh navigation and selected state' do
      received = create(:application, :in_progress, :with_disability_certification)
      received.update!(disability_certification_status: :received)
      signed = create(:application, :in_progress, disability_certification_status: :requested, document_signing_status: :signed)
      overlap = create(:application, :in_progress, :with_disability_certification)
      overlap.update!(disability_certification_status: :received, document_signing_status: :signed)
      selections = {
        'certifications_needing_review' => ['All certifications', [received.id, signed.id, overlap.id]],
        'disability_certs_to_review' => ['Received documents', [received.id, overlap.id]],
        'digitally_signed_needs_review' => ['Digitally signed', [signed.id, overlap.id]]
      }
      selections.each do |filter, (label, ids)|
        get admin_applications_path(view: 'review', filter: filter)
        assert_response :success
        ids.each { |id| assert_select "#application_#{id}", count: 1 }
        (selections.values.first.last - ids).each { |id| assert_select "#application_#{id}", count: 0 }
        assert_select 'nav[aria-label="Certification review filters"] a', count: 3
        assert_select 'nav[aria-label="Certification review filters"] a[aria-current="page"]', text: label, count: 1
      end

      get admin_applications_path(view: 'review', filter: 'certifications_needing_review', status: 'active')
      assert_response :success
      assert_select 'select[name="status"] option[value="active"][selected]', text: 'Active'

      get admin_applications_path(view: 'review', filter: 'certifications_needing_review', q: 'UnmatchedCertificationSearch',
                                  program_group: 'speech', date_range: 'last_30', status: 'in_progress')
      css_select('nav[aria-label="Certification review filters"] a').each do |link|
        query = Rack::Utils.parse_nested_query(URI.parse(link['href']).query)
        assert_equal %w[filter view], query.keys.sort
        assert_equal 'review', query.fetch('view')
        assert_equal 'false', link['data-turbo']
      end
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

    test 'pipeline card names open the next task while headings keep filtering the stage' do
      unassigned = approved_application(approved_at: 10.days.ago)
      unassigned.update!(needs_evaluator_since: 10.days.ago)
      requested = approved_application(approved_at: 8.days.ago)
      product = create(:product, manufacturer: 'Apple', model_number: 'iPhone 18 Pro Max 512GB Pipeline Silver')
      create(:equipment_need, application: requested, product: product, unfulfilled_since: 3.days.ago)
      unsent = approved_application(approved_at: 7.days.ago)
      order = create(:purchase_order, sent_at: nil)
      create(:equipment_item, application: unsent, purchase_order: order, po_assigned_at: 2.days.ago)
      shipping = approved_application(approved_at: 6.days.ago)
      create(:equipment_item, application: shipping, purchase_order: create(:purchase_order, sent_at: 1.day.ago.to_date))
      reporting = approved_application(approved_at: 9.days.ago)
      reporting.update!(report_wait_started_at: 8.days.ago)
      evaluator = create(:evaluator, first_name: 'Morgan', last_name: 'Evaluator')
      evaluation = create(:evaluation, application: reporting, evaluator:)
      bidding = approved_application(approved_at: 4.days.ago)
      bid_need = create(:equipment_need, application: bidding, product: product)
      bid = Equipment::Bidding.new(actor: @admin).create!(
        number: 'DASHBOARD-BID', needs: [{ id: bid_need.id, quantity: 1, lock_version: bid_need.lock_version }]
      )
      award_context = { application_id: bidding.id, tab: 'needs_ordering' }
      award_path = new_admin_purchase_order_path(bid_group_id: bid.id, return_context: award_context)
      shipped = approved_application(approved_at: 5.days.ago)
      create(:equipment_item, application: shipped, shipped_at: 1.day.ago.to_date, tracking_number: 'PIPELINE-SHIPPED')

      get admin_applications_path(view: 'pipeline', q: 'PipelineListCohort', group: 'equipment')

      assert_response :success
      destinations = {
        needs_evaluator: [unassigned, admin_application_path(unassigned, anchor: 'evaluation-status-title')],
        awaiting_report: [reporting, evaluators_evaluation_path(evaluation)],
        needs_fulfillment: [requested, admin_equipment_index_path(application_id: requested.id, tab: 'needs_ordering')],
        awaiting_bid_award: [bidding, award_path],
        ready_to_send_po: [unsent, admin_purchase_order_path(order)],
        awaiting_shipment: [shipping, admin_equipment_index_path(application_id: shipping.id, tab: 'ordered', source: 'vendor')],
        shipment_recorded: [shipped, admin_equipment_index_path(tab: 'shipped', application_id: shipped.id)]
      }
      destinations.each do |stage, (application, destination)|
        stage_link = css_select("a[data-pipeline-stage='#{stage}']").sole
        query = Rack::Utils.parse_nested_query(URI.parse(stage_link['href']).query)
        assert_equal stage.to_s, query['stage']
        assert_equal 'applications_list', stage_link['data-turbo-frame']
        label = application.user.full_name
        label += ' — iPhone' if stage == :needs_fulfillment
        assert_select stage_link.parent, 'a[href=?][data-turbo-frame="_top"]', destination, text: label
      end
      report_card = css_select("a[data-pipeline-stage='awaiting_report']").sole.parent
      assert_select report_card, 'p', text: 'Evaluator: Morgan Evaluator'
      assert_select "tr#application_#{bidding.id} a[href=?][data-turbo-frame='_top']", award_path, text: 'Enter PO details'

      get award_path
      assert_response :success
      assert_select 'h1', text: 'Enter PO details for bid DASHBOARD-BID'
      assert_select 'input[type=hidden][name=bid_group_id][value=?]', bid.id.to_s
      award_context.each { |key, value| assert_select 'input[type=hidden][name=?][value=?]', "return_context[#{key}]", value.to_s }
      assert_select 'a[href=?]', admin_bid_group_path(bid, return_context: award_context), text: 'Back to Bid'

      { awaiting_evaluation: [unassigned, reporting], getting_bids: [requested, bidding] }.each do |stage, applications|
        get admin_applications_path(view: 'pipeline', q: 'PipelineListCohort', group: 'equipment', stage: stage)
        assert_response :success
        ids = css_select('table[aria-label="Approved pipeline applications"] tbody tr').map { |row| row['id'].delete_prefix('application_').to_i }
        assert_equal applications.map(&:id).sort, ids.sort
        assert_select 'input[name="stage"][value=?]', stage.to_s
        assert_select '#application-table h2', text: /#{Applications::ApprovedPipeline::STAGE_FILTERS.fetch(stage).fetch(:label)} \(2 matching\)/
        assert_select 'a', text: 'All stages'
      end

      create(:evaluator)
      get admin_application_path(unassigned)
      assert_response :success
      assert_select '#evaluation-status-title', text: 'Evaluation and Training Status'
      assert_select 'form[action=?] select[name=evaluator_id]', assign_evaluator_admin_application_path(unassigned)
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
      assert_select 'select[name="status"][data-autosubmit-clear-param="filter"]'
      assert_select 'select[name="date_range"][data-autosubmit-clear-param]', count: 0
      assert_select 'a[data-action="click->autosubmit#discardSearch"]', text: 'Clear filters'
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
