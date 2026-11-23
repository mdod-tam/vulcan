# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class DashboardTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)

      @draft_app = create(:application, :draft)
      @in_progress_app = create(:application, :in_progress)
      @approved_app = create(:application, :approved)

      @app_with_pending_proof = create(:application,
                                       status: 'in_progress',
                                       income_proof_status: 'not_reviewed',
                                       residency_proof_status: 'not_reviewed')

      @app_with_disability_cert = create(:application, :in_progress)
      @app_with_disability_cert.update!(disability_certification_status: :received)

      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
    end

    test 'applications page loads the status chart frame' do
      visit admin_applications_path

      assert_selector 'h1', text: 'Applications'

      assert_selector "section[aria-labelledby='applications-heading']"

      scroll_to find('turbo-frame#charts_section')
      assert_selector "turbo-frame#charts_section section[aria-labelledby='charts-heading']"

      assert_selector 'h3#status-breakdown-heading', text: /Application Status Snapshot/
    end

    test 'review cards and the training card appear on their own application views' do
      visit admin_dashboard_path
      assert_no_selector '#common-tasks'
      within('#dashboard-content') do
        assert_text 'Approved applications'
        assert_selector 'li', text: /\d+ applications? awaiting proofs from constituents/
        assert_selector 'li', text: /\d+ applications? with proofs to review/
        assert_selector 'li', text: /\d+ applications? needing cert request/
        assert_selector 'li', text: /\d+ applications? awaiting certifications from providers/
        assert_selector 'li', text: /\d+ applications? with disability certifications to review/
        assert_no_text 'with signed certifications to review'
        assert_selector 'li', text: /\d+ applications? awaiting training/
        assert_selector 'li', text: /\d+ applications? awaiting evaluation/
        assert_selector 'li', text: /\d+ applications? getting bids/
        assert_selector 'li', text: /\d+ applications? needing a PO sent date/
        assert_selector 'li', text: /\d+ applications? needing shipping info/
        assert_no_text 'awaiting delivery confirmation'
        assert_no_text 'An application can need more than one step.'
      end
      assert_selector '#dashboard-content li a', count: 10
      first('#dashboard-content li a').execute_script('this.focus()')
      assert_selector '#dashboard-content li a:focus', text: 'awaiting proofs from constituents'
      page.driver.browser.keyboard.type(:Tab)
      assert_selector '#dashboard-content li a:focus', text: 'with proofs to review'
      take_screenshot('dashboard-application-status-breakdown', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('dashboard-application-status-breakdown-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 800)

      task_links = all('#dashboard-content li a').map { |link| [link.text, link[:href]] }
      task_links.each do |label, destination|
        visit admin_dashboard_path
        click_link label, exact: true
        assert_current_path destination
        assert_selector 'h1', text: 'Applications'
      end

      visit admin_applications_path(view: 'review')
      assert_selector 'h1', text: 'Applications'
      assert_link 'Back to Dashboard', href: admin_dashboard_path
      assert_no_link 'Equipment', href: admin_equipment_index_path
      assert_no_link 'Purchase Orders', href: admin_purchase_orders_path
      within('turbo-frame#applications_list section[aria-labelledby="common-tasks-heading"]') do
        assert_selector 'article.summary-card', count: 3
        assert_selector 'a', text: /Proofs awaiting review/
        assert_selector 'a', text: /Certifications awaiting review/
        assert_selector 'a', text: /Awaiting provider signature/
        assert_selector 'a.summary-card-content', count: 3
      end
      assert_no_selector '#service-assignments'
      take_screenshot('applications-review-common-tasks', html: true, full: true)

      within('nav[aria-label="Application views"]') { click_link 'All applications' }
      assert_no_selector '#common-tasks'
      within('nav[aria-label="Application views"]') { click_link 'Approved pipeline' }
      assert_no_selector '#common-tasks'
      assert_no_selector '#service-assignments'
      within('#training-summary-card') do
        assert_link 'Assign trainer', href: trainers_dashboard_path
        assert_text 'application'
      end
      take_screenshot('approved-pipeline-training-card', html: true, full: true)
      within('nav[aria-label="Application views"]') { click_link 'Review applications' }
      assert_selector 'turbo-frame#applications_list #common-tasks'
      take_screenshot('applications-review-common-tasks-after-tabs', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      assert_selector '#common-tasks a.summary-card-content', count: 3
      take_screenshot('applications-review-common-tasks-narrow', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'review cards open the certification filters and training opens its dashboard' do
      @approved_app.update!(training_requested_at: 1.day.ago)
      signed_application = create(:application, :in_progress, disability_certification_status: :requested, document_signing_status: :signed)
      visit admin_applications_path(view: 'review')
      click_on 'Proofs awaiting review'
      assert_current_path admin_applications_path(view: 'review', filter: 'proofs_needing_review')
      assert_selector 'nav[aria-label="Application views"] a[aria-current="page"]', text: 'Review applications'

      click_on 'Certifications awaiting review'
      assert_current_path admin_applications_path(view: 'review', filter: 'certifications_needing_review')
      assert_selector 'h1', text: 'Applications'
      click_on 'Digitally signed', exact: true
      assert_current_path admin_applications_path(view: 'review', filter: 'digitally_signed_needs_review')
      assert_selector "#application_#{signed_application.id}"
      click_on 'Received documents', exact: true
      assert_current_path admin_applications_path(view: 'review', filter: 'disability_certs_to_review')
      assert_no_selector "#application_#{signed_application.id}"
      click_on 'All certifications', exact: true
      assert_current_path admin_applications_path(view: 'review', filter: 'certifications_needing_review')
      assert_selector "#application_#{signed_application.id}"
      assert_selector "#application_#{@app_with_disability_cert.id}"
      take_screenshot('certification-review-combined-filters', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('certification-review-combined-filters-narrow', html: true, full: true)
      page.current_window.resize_to(1200, 800)

      visit admin_applications_path(view: 'pipeline')

      page.execute_script <<~JS
        for (const [id, value] of [['q', 'Unrelated search'], ['managing_guardian_q', 'Unrelated guardian']]) {
          const input = document.getElementById(id);
          input.value = value;
          input.dispatchEvent(new Event('input', { bubbles: true }));
        }
        document.querySelector('#training-summary-card a').click();
      JS
      assert_current_path trainers_dashboard_path
      assert_selector 'h1', text: 'Training Dashboard'
      assert_nil URI.parse(page.current_url).query
      assert_no_selector '#common-tasks'
      take_screenshot('pipeline-training-card-destination', html: true, full: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'review cards show receipt waits and recorded approval averages' do
      pending = create(:application, :with_id_proof, :with_residency_proof, :with_income_proof,
                       user: create(:constituent, first_name: 'Samuel', last_name: 'Reed'))
      %i[id_proof residency_proof income_proof].each { |name| pending.public_send(name).attachment.update!(created_at: 3.days.ago) }
      certification = create(:application, :with_disability_certification, disability_certification_status: :received,
                                                                           user: create(:constituent, first_name: 'Aisha', last_name: 'Johnson'))
      certification.disability_certification.attachment.update!(created_at: 4.days.ago)
      approved = create(:application, :with_all_proofs, income_proof_status: :approved, residency_proof_status: :approved,
                                                        id_proof_status: :approved, disability_certification_status: :approved)
      approved.income_proof.attachment.update!(created_at: 4.days.ago)
      approved.disability_certification.attachment.update!(created_at: 2.days.ago)
      create(:proof_review, application: approved, admin: @admin, proof_type: :income, reviewed_at: 2.days.ago)
      create(:proof_review, application: approved, admin: @admin, proof_type: :disability_certification, reviewed_at: 1.day.ago)
      provider = create(:application, :in_progress, disability_certification_status: :requested,
                                                    document_signing_status: :sent,
                                                    disability_certification_requested_at: 5.days.ago,
                                                    document_signing_requested_at: 5.days.ago,
                                                    user: create(:constituent, first_name: 'Alex', last_name: 'Morgan'))
      @approved_app.update!(training_requested_at: 3.days.ago, program_disability_groups: ['deafblind'])
      visit admin_applications_path(view: 'review')

      within('#common-tasks article', text: 'Proofs awaiting review') do
        assert_text(/Longest (recorded )?wait/)
        assert_text '3 days'
        assert_link 'Samuel Reed — ID, Residency, and Income', href: admin_application_path(pending, anchor: 'attachments-section')
        assert_text 'Next: Review proofs'
        assert_text(/Average wait to approve:\s+2 days/)
        assert_text 'Based on 1 recorded document approval.'
      end
      within('#common-tasks article', text: 'Certifications awaiting review') do
        assert_text '4 days'
        assert_link 'Aisha Johnson — Certification', href: admin_application_path(certification, anchor: 'disability-certification-section')
        assert_text 'Next: Review certification'
        assert_text(/Average wait to approve:\s+1 day/)
      end
      within('#common-tasks article', text: 'Awaiting provider signature') do
        assert_text '5 days'
        assert_link 'Alex Morgan — Provider signature', href: admin_application_path(provider, anchor: 'disability-certification-section')
        assert_text 'Next: Follow up with provider'
        assert_no_text 'Average wait to approve'
      end
      take_screenshot('review-card-waits-and-approvals', html: true, full: true)
      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('review-card-waits-and-approvals-narrow', html: true, full: true)
      click_link 'Samuel Reed — ID, Residency, and Income'
      assert_current_path(admin_application_path(pending)) { |uri| uri.fragment == 'attachments-section' }
      assert_selector '#attachments-section'
      visit admin_applications_path(view: 'review')
      click_link 'Aisha Johnson — Certification'
      assert_current_path(admin_application_path(certification)) { |uri| uri.fragment == 'disability-certification-section' }
      assert_selector '#disability-certification-section'
      visit admin_applications_path(view: 'review')
      click_on 'Awaiting provider signature'
      assert_current_path admin_applications_path(view: 'review', filter: 'certifications_awaiting_provider')
      assert_selector "#application_#{provider.id}"
      assert_no_selector "#application_#{certification.id}"
      visit admin_applications_path(view: 'pipeline')
      within('#training-summary-card') do
        assert_text 'Longest wait: 3 days'
        assert_link "#{@approved_app.user.full_name} — DeafBlind",
                    href: trainers_dashboard_path(anchor: "training-request-#{@approved_app.id}")
        assert_text 'Average wait to assign trainer: Not recorded'
      end
      take_screenshot('training-card-oldest-request', html: true, full: true)
      click_link "#{@approved_app.user.full_name} — DeafBlind"
      assert_current_path(trainers_dashboard_path) { |uri| uri.fragment == "training-request-#{@approved_app.id}" }
      assert_selector "#training-request-#{@approved_app.id}", text: @approved_app.user.full_name
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'staff workspaces share cards and support keyboard and narrow navigation' do
      trainer = create(:trainer)
      evaluator = create(:evaluator)
      %i[requested scheduled completed cancelled].each do |status|
        create(:training_session, status, trainer: trainer)
        create(:evaluation, evaluator: evaluator, status: status,
                            evaluation_date: status == :requested ? nil : 1.day.from_now,
                            appointment_completed_at: status == :completed ? 1.hour.ago : nil,
                            report_submitted_at: status == :completed ? Time.current : nil)
      end
      create(:equipment_need, unfulfilled_since: 1.day.ago)
      reference_card_style = nil
      [
        ['training', trainers_dashboard_path, 4],
        ['evaluations', evaluators_dashboard_path, 4],
        ['equipment', admin_equipment_index_path, 3],
        ['review', admin_applications_path(view: 'review'), 3],
        ['pipeline', admin_applications_path(view: 'pipeline', group: 'equipment'), 8]
      ].each do |name, path, cards|
        page.current_window.resize_to(1280, 900)
        visit path
        assert_selector 'main', count: 1
        assert_selector 'h1', count: 1
        assert_selector '.summary-card', count: cards
        if name.in?(%w[review pipeline])
          summary = first('.summary-card')
          filters = find('form[data-controller="autosubmit"]')
          table = find('#application-table table')
          assert_operator summary.evaluate_script('this.getBoundingClientRect().top'), :<, filters.evaluate_script('this.getBoundingClientRect().top')
          assert_operator filters.evaluate_script('this.getBoundingClientRect().bottom'), :<=, table.evaluate_script('this.getBoundingClientRect().top')
          if name == 'pipeline'
            height = find_by_id('pipeline-status-cards').evaluate_script('this.getBoundingClientRect().height')
            assert_operator height, :<=, 300, 'The eight status cards should fit within one third of a 900px desktop viewport.'
          end
        end
        assert_link 'Back to Dashboard', href: admin_dashboard_path
        page.all('table').to_a.each do |table|
          assert table[:'aria-label'].present? || table[:'aria-labelledby'].present? || table.has_css?('caption', visible: :all),
                 "A table on the #{name} page needs an accessible name."
        end
        page.driver.browser.keyboard.type(:Tab)
        assert_selector 'a.skip-link[href="#main-content"]:focus'
        page.driver.browser.keyboard.type(:Enter)
        assert_selector '#main-content:focus'
        page.driver.browser.keyboard.type(:Tab)
        assert_selector "a[href='#{admin_dashboard_path}']:focus", text: 'Back to Dashboard'
        assert_operator find('a:focus').evaluate_script('parseFloat(getComputedStyle(this).outlineWidth)'), :>=, 2

        if cards.positive?
          card_style = first('.summary-card').evaluate_script(<<~JS)
            (() => {
              const style = getComputedStyle(this);
              return [style.borderRadius, style.boxShadow, style.borderWidth];
            })()
          JS
          reference_card_style ||= card_style
          assert_equal reference_card_style, card_style
        end
        take_screenshot("unified-#{name}-workspace", html: true, full: true)

        page.current_window.resize_to(390, 844)
        width = page.evaluate_script('document.documentElement.scrollWidth')
        take_screenshot("unified-#{name}-workspace-narrow", html: true, full: true)
        assert_operator width, :<=, 390, "Horizontal overflow on #{name}"
        region = page.all('[role="region"][tabindex="0"]').find do |element|
          element.evaluate_script('this.scrollWidth > this.clientWidth')
        end
        next unless region

        region.execute_script('this.scrollLeft = 0; this.focus()')
        page.driver.browser.keyboard.type(:Right)
        assert_selector '[role="region"][tabindex="0"]:focus' do |focused|
          focused.evaluate_script('this.scrollLeft').positive?
        end
        assert_equal '0', region[:tabindex]
      end
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'view reports button links to reports page' do
      visit admin_dashboard_path

      click_on 'Reports'

      assert_current_path admin_reports_path

      assert_selector 'h1', text: 'Reports'
      assert_selector '#report-title', text: 'Applications'
    end

    test 'admin action links are present and selected links navigate' do
      visit admin_dashboard_path

      assert_selector 'a', text: 'Apply for Constituent'
      assert_selector 'a', text: 'Applications'
      assert_selector 'a', text: 'Reports'
      assert_selector 'a', text: 'Edit Policies'
      assert_selector 'a', text: 'Manage Products'

      click_on 'Edit Policies'
      assert_current_path admin_policies_path
      visit admin_dashboard_path

      click_on 'Manage Products'
      assert_current_path admin_products_path
      visit admin_dashboard_path

      click_on 'Apply for Constituent'
      assert_current_path new_admin_paper_application_path, ignore_query: true
      visit admin_dashboard_path

      click_on 'Reports'
      assert_current_path admin_reports_path
    end

    test 'immediate apply for constituent click navigates and checks selected console errors' do
      console_errors = []
      if page.driver.respond_to?(:browser) && page.driver.browser.respond_to?(:on)
        page.driver.browser.on(:console) do |message|
          next unless message.respond_to?(:type) && message.type == :error

          console_errors << message.text
        end
      end

      visit admin_dashboard_path
      click_on 'Apply for Constituent'

      assert_current_path new_admin_paper_application_path, ignore_query: true
      assert_selector 'h1', text: 'Apply for Constituent'
      assert_empty console_errors.grep(/RangeError|Maximum call stack size exceeded|getComputedStyle/i)
    end

    test 'recent notifications stay compact with accessible dashboard actions' do
      notifications = %w[id residency income].map do |proof_type|
        create(:notification, recipient: @admin, actor: @admin, notifiable: @approved_app,
                              action: 'proof_approved', metadata: { proof_type: proof_type }, created_at: 1.day.ago)
      end
      page.current_window.resize_to(1280, 800)
      visit admin_dashboard_path

      card = find('section[aria-labelledby="notifications-heading"]')
      within(card) do
        assert_selector 'li', count: 3
        assert_text 'ID proof approved'
        assert_text 'Residency proof approved'
        assert_text 'Income proof approved'
        assert_selector 'button', text: 'Mark as read', count: 3
      end
      assert_operator card.evaluate_script('this.getBoundingClientRect().height'), :<=,
                      page.evaluate_script('window.innerHeight / 4')
      take_screenshot('dashboard-compact-recent-notifications', html: true, full: true)

      within("#notification_#{notifications.first.id}") do
        click_button 'Mark as read'
        assert_no_button 'Mark as read'
      end
      assert notifications.first.reload.read_at.present?
      assert_operator card.evaluate_script('this.getBoundingClientRect().height'), :<=,
                      page.evaluate_script('window.innerHeight / 4')
      take_screenshot('dashboard-compact-notification-after-read', html: true, full: true)

      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      within(card) do
        assert_text 'Residency proof approved'
        assert_text 'Income proof approved'
        assert_selector 'button', text: 'Mark as read', count: 2
      end
      take_screenshot('dashboard-compact-recent-notifications-narrow', html: true, full: true)

      assert_selector "a[aria-label*='constituent']"
      assert_selector "a[aria-label*='applications']"
      assert_selector "a[aria-label*='policies']"
      assert_selector "a[aria-label*='products']"
      assert_selector "a[aria-label*='reports']"

      page.all('a[aria-label]').to_a.each do |button|
        assert button['aria-label'].present?, "Button missing aria-label: #{button.text}"
      end

      page.current_window.resize_to(1280, 800)
      visit admin_applications_path(view: 'review')
      card = find('.compact-notifications')
      within(card) do
        assert_selector 'li', count: 3
        assert_text 'Residency proof approved'
        assert_selector 'button', text: 'Mark as read', count: 2
      end
      assert_operator card.evaluate_script('this.getBoundingClientRect().height'), :<=, 200
      take_screenshot('applications-compact-recent-notifications', html: true, full: true)
      within("#notification_#{notifications.second.id}") { click_button 'Mark as read' }
      assert notifications.second.reload.read_at.present?
      page.current_window.resize_to(390, 844)
      page.execute_script('window.scrollTo(0, 0)')
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      within(card) { assert_selector 'button', text: 'Mark as read', count: 1 }
      take_screenshot('applications-compact-notifications-after-read-narrow', html: true, full: true)

      notification = notifications.last
      notification.mark_delivery_suppressed!('all_disabled')
      page.current_window.resize_to(1280, 800)
      visit admin_dashboard_path
      within("#notification_#{notification.id}") do
        assert_no_selector '[data-delivery-status] > .badge'
        find('summary', text: 'Details').click
        assert_text DeliveryStatusPresenter.new(notification).description
        find('summary', text: 'Details').click
        click_button 'Mark as read'
        assert_no_button 'Mark as read'
        assert_no_selector '[data-delivery-status] > .badge'
        assert_selector 'summary', text: 'Details'
      end
      take_screenshot('dashboard-recent-notifications-without-delivery-badges', html: true, full: true)
      visit admin_applications_path(view: 'review')
      within('.compact-notifications') do
        assert_no_selector '[data-delivery-status] > .badge'
        assert_selector 'summary', text: 'Details'
      end
      take_screenshot('applications-recent-notifications-without-delivery-badges', html: true, full: true)
      visit notifications_path(scope: 'all')
      assert_selector "#notification_#{notification.id} [data-delivery-status] > .badge"
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'equipment and configuration tools use the established dashboard rows and linked settings pages' do
      flag = FeatureFlag.find_by!(name: 'vouchers_enabled')
      flag.update!(enabled: false)
      page.current_window.resize_to(1440, 1000)
      visit admin_dashboard_path
      assert_selector 'h1', count: 1, text: 'Admin Dashboard'
      assert_no_selector 'nav[aria-label="Equipment and program tools"]'
      [1440, 1280].each do |width|
        page.current_window.resize_to(width, 1000)
        heights = page.all('div.mb-8.space-y-8 .grid > a.btn').map do |button|
          button.evaluate_script('this.getBoundingClientRect().height')
        end
        assert_equal 12, heights.length
        assert_operator heights.max - heights.min, :<=, 1
      end
      take_screenshot('dashboard-matching-action-button-heights', html: true, full: true)
      page.current_window.resize_to(1440, 1000)
      within('section[aria-labelledby="equipment-tools-heading"]') do
        assert_link 'Equipment', href: admin_equipment_index_path
        assert_link 'iCanConnect filing preparation', href: admin_icanconnect_filing_prep_path
      end
      configuration = find('section[aria-labelledby="configuration-tools-heading"]')
      links = configuration.all('a')
      assert_equal([admin_policies_path, admin_feature_flags_path], links.first(2).map { |link| URI.parse(link[:href]).path })
      links.first.execute_script('this.focus()')
      page.driver.browser.keyboard.type(:Tab)
      assert_selector "section[aria-labelledby='configuration-tools-heading'] a[href='#{admin_feature_flags_path}']:focus"
      take_screenshot('dashboard-established-tool-rows', html: true, full: true)

      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('dashboard-established-tool-rows-narrow', html: true, full: true)
      within(configuration) { click_link 'Feature Flags' }
      assert_current_path admin_feature_flags_path
      assert_link 'System Policies', href: admin_policies_path
      assert_link 'communication controls', href: admin_email_templates_path(anchor: 'email-delivery')
      assert_link 'Back to Dashboard', href: admin_dashboard_path
      within("[data-feature-flag='vouchers_enabled']") do
        assert_text 'Disabled'
        assert_selector 'input[type="submit"][aria-label="Enable Vouchers"]'
        click_button 'Enable'
      end
      assert_text 'Feature flag updated successfully'
      assert flag.reload.enabled?
      within("[data-feature-flag='vouchers_enabled']") do
        assert_text 'Enabled'
        assert_selector 'input[type="submit"][aria-label="Disable Vouchers"]'
      end
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      table_region = find('[role="region"][aria-label="Workflow feature flags"]')
      assert table_region.evaluate_script('this.scrollWidth > this.clientWidth')
      table_region.execute_script('this.scrollLeft = 0; this.focus()')
      take_screenshot('feature-flags-linked-settings-narrow', html: true, full: true)
      page.driver.browser.keyboard.type(:Right)
      assert_selector '[role="region"][aria-label="Workflow feature flags"]' do |region|
        region.evaluate_script('this.scrollLeft').positive?
      end
      take_screenshot('feature-flags-narrow-keyboard-scroll', html: true, full: true)
      page.driver.browser.keyboard.type(*Array.new(20, :Right))
      assert_selector '[role="region"][aria-label="Workflow feature flags"]' do |region|
        region.evaluate_script('this.scrollLeft + this.clientWidth >= this.scrollWidth - 1')
      end
      take_screenshot('feature-flags-narrow-actions', html: true, full: true)
      event = Event.where(action: 'feature_flag_toggled', user: @admin, auditable: flag).sole
      assert_equal false, event.metadata['old_value']
      assert_equal true, event.metadata['new_value']

      click_link 'System Policies'
      assert_current_path admin_policies_path
      assert_selector 'h1', count: 1, text: 'System Policies'
      assert_link 'Feature Flags', href: admin_feature_flags_path
      click_link 'Back to Dashboard'
      assert_current_path admin_dashboard_path
    ensure
      page.current_window.resize_to(1200, 800)
    end
  end
end
