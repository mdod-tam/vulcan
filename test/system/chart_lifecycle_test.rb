# frozen_string_literal: true

require 'application_system_test_case'

class ChartLifecycleTest < ApplicationSystemTestCase
  test 'all report charts and the lazy applications chart survive resizing and Turbo navigation' do
    FeatureFlag.enable!(:vouchers_enabled)
    product = create(:product, device_types: ['Tablet'])
    application = create(:application, skip_proofs: true, status: :in_progress)
    evaluation = create(:evaluation, :completed, application: application, constituent: application.user)
    evaluation.update!(recommended_product_ids: [product.id],
                       products_tried: [{ 'product_id' => product.id.to_s, 'reaction' => 'Recorded during evaluation' }])
    application.update!(fulfillment_type: :equipment, equipment_po_sent_at: Time.current)
    system_test_sign_in(create(:admin))
    visit admin_reports_path
    assert_selector 'canvas', count: 15
    assert_charts_sized(15)
    capture('reports-vouchers-on-wide')
    %w[Current Previous].product(%w[Applications Vouchers Services]).each do |period, subject|
      assert_selector "[data-chart-title-value='#{period} FY #{subject}'] canvas"
    end
    assert_selector 'dt', text: 'Applications Created:', count: 2
    assert_selector 'dt', text: 'Vouchers Issued:', count: 2
    assert_selector '[data-chart-index-axis-value="y"] canvas'
    page.current_window.resize_to(390, 844)
    assert_charts_sized(15)
    capture('reports-vouchers-on-narrow')
    page.current_window.resize_to(1200, 800)
    page.driver.browser.page.command('Emulation.setDeviceMetricsOverride', width: 1198, height: 800, deviceScaleFactor: 2, mobile: false)
    assert_charts_sized(15, dpr: 2)
    page.driver.browser.page.command('Emulation.clearDeviceMetricsOverride')
    page.current_window.resize_to(1200, 800)
    assert_charts_sized(15, dpr: 1)
    capture('reports-after-dpr-change')

    initial_controller_count = page.evaluate_script('Stimulus.controllers.length')
    5.times do
      turbo_visit(admin_applications_path)
      assert_selector 'h1', text: 'Applications'
      page.execute_script('document.getElementById("charts_section").scrollIntoView()')
      assert_selector '#charts_section canvas'
      turbo_visit(admin_reports_path)
      assert_selector 'canvas', count: 15
      assert_charts_sized(15)
      assert_equal initial_controller_count, page.evaluate_script('Stimulus.controllers.length')
    end

    FeatureFlag.disable!(:vouchers_enabled)
    visit admin_reports_path
    assert_no_selector '#voucher-statistics-heading'
    assert_no_selector '#vendor-activity-heading'
    assert_selector 'canvas', count: 10
    assert_charts_sized(10)
    capture('reports-vouchers-off-wide')

    visit admin_applications_path
    page.execute_script('document.getElementById("charts_section").scrollIntoView()')
    assert_selector '#charts_section canvas'
    assert_charts_sized(1)
    capture('applications-lazy-chart')
    page.current_window.resize_to(390, 844)
    assert_charts_sized(1)
    capture('applications-lazy-chart-narrow')
  end

  test 'application modal submission closes the dialog and replaces the current page' do
    application = create(:application, skip_proofs: true, status: :in_progress)
    system_test_sign_in(create(:admin))
    visit admin_user_path(application.user)
    find('[data-controller="application-modal"] button[data-action="click->application-modal#open"]').click
    assert_selector '#application-modal[open]'
    within '#application-modal' do
      assert_text application.user.full_name
      click_button 'Edit', exact: true
    end
    assert_selector '#application-edit-modal[open] form'
    capture('application-modal-edit')
    page.execute_script('window.__modalTurboVisits = []; document.addEventListener("turbo:visit", e => window.__modalTurboVisits.push(e.detail))')
    within '#application-edit-modal' do
      fill_in 'application_medical_provider_name', with: 'Updated Professional'
      click_button 'Update Application'
    end
    assert_no_selector 'dialog[open]'
    assert_equal 'Updated Professional', application.reload.medical_provider_name
    assert_equal 'replace', page.evaluate_script('window.__modalTurboVisits.at(-1).action')
    assert_empty page.evaluate_script('window.__systemTestErrors')
    capture('application-modal-saved')
  end

  test 'vendor chart resizes on every reveal without reconstruction' do
    FeatureFlag.enable!(:vouchers_enabled)
    vendor = create(:vendor, vendor_authorization_status: :approved, w9_status: :approved, terms_accepted_at: 1.day.ago)
    create(:voucher_transaction, vendor: vendor, amount: 125)
    system_test_sign_in(vendor)
    visit vendor_portal_dashboard_path
    assert_selector '#monthly-totals-chart.hidden', visible: :all
    assert_equal 1, chart_state.size
    assert_equal [125], page.evaluate_script("Stimulus.controllers.find(c => c.identifier === 'chart').chart.data.datasets[0].data")
    initial_id = chart_state.first['id']
    capture('vendor-chart-hidden')
    2.times do
      click_button 'Show Chart'
      assert_selector '#monthly-totals-chart canvas'
      assert_charts_sized(1)
      assert_equal initial_id, chart_state.first['id']
      capture('vendor-chart-revealed')
      page.current_window.resize_to(390, 844)
      assert_charts_sized(1)
      capture('vendor-chart-narrow')
      page.current_window.resize_to(1200, 800)
      assert_charts_sized(1)
      click_button 'Hide Chart'
      assert_selector '#monthly-totals-chart.hidden', visible: :all
    end
  end

  private

  def turbo_visit(path)
    page.execute_script(<<~JS, path)
      document.documentElement.dataset.navigationComplete = "false";
      document.addEventListener("turbo:load", () => {
        document.documentElement.dataset.navigationComplete = "true";
      }, { once: true });
      Turbo.visit(arguments[0]);
    JS
    assert_selector 'html[data-navigation-complete="true"]', visible: :all
  end

  def chart_state
    page.evaluate_script(<<~JS)
      Stimulus.controllers.filter(c => c.identifier === 'chart').map(c => {
        const chart = c.chart, canvas = c.canvasTarget, parent = canvas.parentElement;
        return { id: chart.id, width: chart.width, height: chart.height,
          cssWidth: canvas.getBoundingClientRect().width, cssHeight: canvas.getBoundingClientRect().height,
          parentWidth: parent.clientWidth, backingWidth: canvas.width, backingHeight: canvas.height,
          dpr: chart.currentDevicePixelRatio, instances: Object.keys(chart.constructor.instances).length,
          description: !!document.getElementById(canvas.getAttribute('aria-describedby')) };
      })
    JS
  end

  def assert_charts_sized(count, dpr: nil)
    Timeout.timeout(10) do
      loop do
        states = chart_state
        break if states.size == count && states.all? do |c|
          c['width'].positive? && c['height'].positive? &&
          (c['width'] - c['parentWidth']).abs <= 1 &&
          (c['backingWidth'] - (c['cssWidth'] * c['dpr'])).abs <= 2 &&
          (c['backingHeight'] - (c['cssHeight'] * c['dpr'])).abs <= 2 &&
          c['instances'] == count && c['description'] && (!dpr || c['dpr'] == dpr)
        end

        sleep 0.05
      end
    end
    assert_empty page.evaluate_script('window.__systemTestErrors')
  rescue Timeout::Error
    flunk "Canvas sizing timed out: DPR=#{page.evaluate_script('window.devicePixelRatio')}, charts=#{chart_state.to_json}"
  end

  def capture(label)
    assert_empty page.evaluate_script('window.__systemTestErrors')
    @screenshot_artifact_label = label
    increment_unique
    page.save_screenshot(image_path, full: true) # rubocop:disable Lint/Debugger -- Required chart render evidence.
    File.write(image_path.sub(/\.png\z/, '.html'), page.html)
    write_screenshot_sidecar(image_path, label: label, html_saved: true)
    File.write(image_path.sub(/\.png\z/, '.charts.json'), JSON.pretty_generate(chart_state))
    puts screenshot_log_message(image_path)
  ensure
    @screenshot_artifact_label = nil
  end
end
