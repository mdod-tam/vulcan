# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ApplicationsListSystemTest < ApplicationSystemTestCase
    include SystemTestEvidence

    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      ensure_system_audit_actor!
      @admin = create(:admin)
    end

    test 'review headers sort the current status duration and preserve filters through Turbo updates' do
      older = review_application('ZuluSorting', days: 31, created_at: 60.days.ago)
      newer = review_application('AlphaSorting', days: 4, created_at: 40.days.ago, with_proof: true)
      old_query_only = review_application('SortOnly', days: 2, created_at: 10.days.ago)
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_applications_path

      find_field('q').click
      assert_selector 'input#q:focus'
      fill_in 'q', with: 'Sort'
      assert_selector '#applications_list input#q[value="Sort"]'
      assert_selector '#application-table tbody tr.application-row', count: 3
      take_screenshot('review-search-after-paused-typing', html: true, full: true)
      assert_selector 'input#q:focus'
      point = page.evaluate_script <<~JS
        (() => {
          const frame = document.getElementById('applications_list');
          let formRequests = 0;
          frame.addEventListener('turbo:before-fetch-request', event => {
            if (event.target.tagName === 'FORM') formRequests += 1;
            if (event.target === frame && event.detail.url.searchParams.get('sort') === 'applicant') {
              const input = document.getElementById('q');
              window.pendingSort = { value: input.value, rendered: input.getAttribute('value'), formRequests };
            }
          }, true);
          const box = frame.querySelector('th a[href*="sort=applicant"]').getBoundingClientRect();
          return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
        })()
      JS
      browser = page.driver.browser
      browser.keyboard.type('ing')
      browser.mouse.click(x: point.fetch('x'), y: point.fetch('y'), wait: 0)
      assert_field 'q', with: 'Sorting'
      assert_selector 'input#q[value="Sorting"]'
      assert_selector 'th[aria-sort="ascending"] a', text: /Applicant/i
      assert_equal({ 'value' => 'Sorting', 'rendered' => 'Sort', 'formRequests' => 0 }, page.evaluate_script('window.pendingSort'))
      assert_no_selector "#application_#{old_query_only.id}"
      assert_equal [newer.id, older.id], displayed_application_ids
      query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
      assert_equal 'Sorting', query['q']
      assert_equal 'applicant', query['sort']
      take_screenshot('sort-with-pending-search', html: true, full: true)

      fill_in 'managing_guardian_q', with: 'Guar'
      assert_text 'No applications found'
      assert_selector 'input#managing_guardian_q:focus'
      page.driver.browser.keyboard.type('dian')
      assert_selector 'input#managing_guardian_q[value="Guardian"]'
      assert_selector 'input#managing_guardian_q:focus'
      take_screenshot('guardian-search-after-paused-typing', html: true, full: true)
      click_link 'Clear filters'
      assert_field 'q', with: ''
      assert_field 'managing_guardian_q', with: ''
      fill_in 'q', with: 'Sorting'
      assert_selector '#application-table tbody tr.application-row', count: 2
      sort_header('Status').click
      assert_selector 'th[aria-sort="descending"] a', text: /Status/i
      assert_equal [older.id, newer.id], displayed_application_ids
      assert_selector "#application_#{older.id}", text: '31 days'
      assert_equal 'Sorting', find_field('q').value
      take_screenshot('review-status-longest-first', html: true, full: true)

      sort_header('Status').click
      assert_selector 'th[aria-sort="ascending"] a', text: /Status/i
      assert_equal [newer.id, older.id], displayed_application_ids
      sort_header('Applicant').click
      assert_selector 'th[aria-sort="ascending"] a', text: /Applicant/i
      assert_equal [newer.id, older.id], displayed_application_ids
      sort_header('Created').click
      assert_selector 'th[aria-sort="descending"] a', text: /Created/i
      assert_equal [newer.id, older.id], displayed_application_ids
      sort_header('Next action').click
      assert_selector 'th[aria-sort="ascending"] a', text: /Next action/i
      assert_equal [older.id, newer.id], displayed_application_ids

      select 'Awaiting proof', from: 'status'
      assert_selector '#applications_list select#status option[value="awaiting_proof"][selected]', visible: :all
      assert_selector 'th[aria-sort="ascending"] a', text: /Next action/i
      assert_equal [older.id, newer.id], displayed_application_ids
      within('nav[aria-label="Application views"]') { click_link 'All applications' }
      assert_selector "#application_#{older.id}", text: '31 days'
      assert_equal 'Sorting', find_field('q').value
      take_screenshot('all-applications-status-age', html: true, full: true)

      page.current_window.resize_to(390, 1100)
      assert_selector "#application_#{older.id}"
      assert_equal page.evaluate_script('document.documentElement.clientWidth'), page.evaluate_script('document.documentElement.scrollWidth')
      take_screenshot('review-sort-mobile', html: true, full: true)
      page.current_window.resize_to(1400, 1000)
      within("#application_#{newer.id}") { click_link 'Review proof' }
      assert_current_path admin_application_path(newer), ignore_query: true
      assert_selector '#attachments-section'
      take_screenshot('review-next-action-destination', html: true, full: true)
    ensure
      page.current_window.resize_to(1400, 1000)
    end

    test 'a delayed search response keeps newer text after focus moves to another field' do
      application = review_application('DelayedSorting', days: 3, created_at: 4.days.ago)
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_applications_path

      browser = page.driver.browser
      held = Queue.new
      hold_next = true
      browser.network.intercept(pattern: '*/admin/applications*', request_stage: 'Response')
      browser.on(:request) do |request|
        query = Rack::Utils.parse_nested_query(URI.parse(request.url).query)
        if hold_next && query['q'] == 'Sort'
          hold_next = false
          held << request
        else
          request.continue
        end
      end
      page.execute_script <<~JS
        document.addEventListener('turbo:before-frame-render', event => {
          if (event.target.id === 'applications_list' && event.detail.newFrame.querySelector('#q')?.value === 'Sort') {
            window.oldSearchResponseRendered = true;
          }
        });
      JS

      fill_in 'q', with: 'Sort'
      request = held.pop(timeout: 10)
      assert request, 'the older search response should be held'
      browser.keyboard.type('ing', :Tab)
      request.continue

      assert_selector 'input#q[value="Sorting"]'
      assert_selector 'input#managing_guardian_q:focus'
      assert_selector "#application_#{application.id}"
      assert page.evaluate_script('window.oldSearchResponseRendered'), 'the older response must actually reach the frame'
      take_screenshot('delayed-search-after-focus-change', html: true, full: true)
      click_link 'Clear filters'
      assert_field 'q', with: ''
      assert_field 'managing_guardian_q', with: ''
    ensure
      request.continue if request && !request.status?(:continued)
      browser&.network&.intercept(pattern: 'about:blank')
    end

    test 'choosing a status leaves the review task queue and keeps the other filters' do
      received = create(:application, :in_progress,
                        disability_certification_status: :received,
                        user: create(:constituent, last_name: 'QueueChange'), created_at: 2.days.ago)
      awaiting = create(:application,
                        status: :awaiting_dcf,
                        disability_certification_status: :requested,
                        user: create(:constituent, last_name: 'QueueChange'), created_at: 2.days.ago)
      sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_applications_path(view: 'review')
      find('#common-tasks a[href*="filter=certifications_needing_review"]').click
      within('nav[aria-label="Certification review filters"]') { click_link 'Received documents' }
      assert_selector "#application_#{received.id}"
      assert_no_selector "#application_#{awaiting.id}"
      fill_in 'q', with: 'QueueChange'
      assert_selector 'input#q[value="QueueChange"]'
      select 'Last 30 days', from: 'date_range'
      assert_selector 'input[name="filter"][value="disability_certs_to_review"]', visible: :all
      take_screenshot('review-task-before-status-change', html: true, full: true)

      select 'Awaiting certification', from: 'status'

      assert_selector "#application_#{awaiting.id}"
      assert_no_selector "#application_#{received.id}"
      assert_no_selector 'input[name="filter"]', visible: :all
      assert_field 'q', with: 'QueueChange'
      assert_field 'date_range', with: 'last_30'
      query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
      assert_nil query['filter']
      assert_equal 'awaiting_dcf', query['status']
      take_screenshot('review-task-after-status-change', html: true, full: true)
    end

    test 'Dashboard enters the approved pipeline and date filters update cards and the actionable list together' do
      older = approved_application('Old backlog', days: 150)
      recent = approved_application('Recent backlog', days: 10)
      no_equipment = approved_application('Training requested', days: 40)
      no_equipment.update!(equipment_needs_initialized_at: 20.days.ago, equipment_needs_decided_at: 20.days.ago, training_requested_at: 5.days.ago)
      voucher_application = approved_application('Expired voucher', days: 250)
      voucher_application.update!(fulfillment_type: :voucher)
      create(:voucher, application: voucher_application, issued_at: Policy.voucher_validity_period.ago - 8.days, remaining_value: 180)
      tracking_only = approved_application('Tracking saved', days: 5)
      create(:equipment_item, application: tracking_only, tracking_number: 'SAVED-BEFORE-SHIPPING', shipped_at: nil)
      sign_in(@admin, bypass_mfa_enrollment: true)

      within('#dashboard-content') { click_link 'Open approved pipeline' }
      assert_selector 'nav[aria-label="Application views"] a[aria-current="page"]', text: 'Approved pipeline'
      fill_in 'q', with: 'PipelinePolish'
      assert_selector "#application_#{older.id}"
      assert_selector "#application_#{recent.id}"
      assert_selector '[data-pipeline-stage="needs_evaluator"]', text: '2'
      assert_selector '[data-pipeline-stage="awaiting_shipment"]', text: 'Enter shipping info'
      assert_selector '[data-pipeline-stage="awaiting_delivery"]', text: 'Awaiting delivery'
      assert_selector '[data-pipeline-stage="shipment_recorded"]', text: 'View shipment history'
      assert_selector "#application_#{tracking_only.id}", text: '0 of 1 unit shipped'
      assert_no_selector '[data-pipeline-stage="voucher_expired"]'
      assert_selector '[data-pipeline-stage]', count: 8
      take_screenshot('approved-pipeline-equipment', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('approved-pipeline-stages-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 800)

      select 'Last 30 days', from: 'date_range'
      assert_no_selector "#application_#{older.id}"
      assert_selector "#application_#{recent.id}"
      assert_selector '[data-pipeline-stage="needs_evaluator"]', text: '1'
      find('[data-pipeline-stage="needs_evaluator"]').click
      assert_selector '[data-pipeline-stage="needs_evaluator"][aria-current="page"]'
      take_screenshot('approved-pipeline-date-and-stage', html: true, full: true)

      select 'All time', from: 'date_range'
      within('nav[aria-label="Approved application groups"]') { find('a', text: /Vouchers/).click }
      find('[data-pipeline-stage="voucher_expired"]').click
      assert_selector "#application_#{voucher_application.id}", text: '$180.00'
      assert_no_selector '[data-pipeline-stage="needs_evaluator"]'
      take_screenshot('approved-pipeline-expired-value', html: true, full: true)

      within('nav[aria-label="Approved application groups"]') { find('a', text: /No equipment needed/).click }
      assert_selector "#application_#{no_equipment.id}", text: 'Open training'
      assert_no_selector '[data-pipeline-stage="voucher_expired"]'
      take_screenshot('approved-pipeline-training-only', html: true, full: true)
      select 'Last 30 days', from: 'date_range'
      assert_text 'No applications in this fulfillment group.'
      take_screenshot('approved-pipeline-empty-filter', html: true, full: true)
    end

    test 'fulfillment card names the device family and the next bid action' do
      application = create(:application, :approved, :with_all_proofs,
                           user: create(:constituent, first_name: 'Samuel', last_name: 'Reed'),
                           fulfillment_type: :equipment, equipment_needs_initialized_at: 1.day.ago)
      product = create(:product, name: 'Apple iPhone 18 Pro Max', manufacturer: 'Apple', model_number: 'iPhone 18 Pro Max 512GB Pipeline Blue')
      need = create(:equipment_need, application: application, product: product,
                                     disability_setup_group: nil, unfulfilled_since: 1.day.ago)
      card_selector = 'article:has([data-pipeline-stage="needs_fulfillment"])'
      pipeline_path = admin_applications_path(view: 'pipeline', group: 'equipment', q: 'Reed')
      equipment_path = admin_equipment_index_path(tab: 'needs_ordering', application_id: application.id)
      sign_in(@admin, bypass_mfa_enrollment: true)
      page.current_window.resize_to(1200, 800)
      visit pipeline_path

      within(card_selector) do
        assert_link 'Samuel Reed — iPhone', href: equipment_path
        assert_text 'Next: Prepare bid'
        assert_selector 'p', text: 'Average wait: 1 day', exact_text: true
        assert_no_text '1 days'
        assert_no_text 'Apple'
        assert_no_text '18 Pro Max'
        assert_no_text 'Review equipment'
      end
      within("#application_#{application.id}") do
        assert_link 'Prepare bid', href: equipment_path
        assert_no_link 'Review equipment'
      end
      take_screenshot('approved-pipeline-fulfillment-device', html: true, full: true)
      take_evidence_screenshot('approved-pipeline-fulfillment-card', html: true, selector: card_selector)

      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      assert_selector card_selector, text: 'Samuel Reed — iPhone'
      take_screenshot('approved-pipeline-fulfillment-device-narrow', html: true, full: true)
      within(card_selector) { click_link 'Samuel Reed — iPhone' }
      assert_current_path equipment_path
      assert_selector 'h1', text: 'Needs bid number'
      assert_text product.name
      assert_text 'Samuel Reed'

      need.update!(disability_setup_group: 'deaf')
      page.current_window.resize_to(1200, 800)
      visit pipeline_path
      within(card_selector) do
        assert_text 'Needs bid number'
        assert_link 'Samuel Reed — iPhone', href: equipment_path
      end
      within("#application_#{application.id}") { assert_link 'Enter bid number', href: equipment_path }
      take_evidence_screenshot('approved-pipeline-fulfillment-ready-card', html: true, selector: card_selector)

      unselected = create(:application, :approved, :with_all_proofs,
                          user: create(:constituent, first_name: 'Robin', last_name: 'CatalogChoice'),
                          fulfillment_type: :equipment, equipment_needs_initialized_at: 1.day.ago)
      visit admin_applications_path(view: 'pipeline', group: 'equipment', q: 'CatalogChoice')
      within("#application_#{unselected.id}") { click_link 'Choose equipment for bid' }
      assert_current_path edit_admin_application_equipment_needs_path(unselected), ignore_query: true
      select product.catalog_label, from: 'Catalog model'
      fill_in 'Reason for adjustment', with: 'Choose the device for the bid.'
      take_screenshot('approved-pipeline-unselected-device-editor', html: true, full: true)
      click_button 'Save purchasing needs'
      assert_current_path admin_equipment_index_path(tab: 'needs_ordering', application_id: unselected.id)
      assert_text 'Purchasing needs updated.'
      assert_text product.name
      assert_text 'Robin CatalogChoice'
      take_screenshot('approved-pipeline-selected-device-queue', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    private

    def review_application(name, days:, created_at:, with_proof: false)
      application = create(:application, :in_progress, user: create(:constituent, last_name: name), created_at: created_at)
      if with_proof
        application.residency_proof.attach(io: file_fixture('income_proof.pdf').open, filename: 'residency.pdf', content_type: 'application/pdf')
        mark_document_clean!(application.residency_proof.blob, user: @admin)
      end
      application.transition_status!(:awaiting_proof, actor: @admin)
      application.status_changes.last.update!(changed_at: days.days.ago)
      application
    end

    def approved_application(name, days:)
      application = create(:application, :approved, :with_all_proofs, user: create(:constituent, last_name: "#{name} PipelinePolish"), created_at: 1.year.ago)
      application.status_changes.create!(from_status: 'in_progress', to_status: 'approved', changed_at: days.days.ago, user: @admin, change_type: :status)
      application
    end

    def sort_header(text)
      find('#application-table th a', text: /#{Regexp.escape(text)}/i)
    end

    def displayed_application_ids
      all('#application-table tbody tr.application-row').map { |row| row[:id].delete_prefix('application_').to_i }
    end
  end
end
