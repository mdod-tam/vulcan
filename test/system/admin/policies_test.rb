# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class PoliciesTest < ApplicationSystemTestCase
    def setup
      @admin = create(:admin)

      @policy = Policy.find_or_create_by!(key: 'max_training_sessions') do |p|
        p.value = 3
      end

      setup_fpl_policies

      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
    end

    test 'policy editing saves labeled values and links to related settings at desktop and narrow widths' do
      recovery_period = Policy.find_or_create_by!(key: 'account_recovery_rate_period') { |policy| policy.value = 1 }
      visit admin_policies_path
      wait_for_turbo

      assert_selector 'h1', text: 'System Policies', count: 1
      assert_text 'Federal Poverty Level (FPL) Settings'
      fill_in 'Base FPL for 1 person', with: '16000'
      fill_in 'Base FPL added for each person above eight', with: '6000'
      assert_selector "#policy_#{recovery_period.id}_unit", text: 'hours'
      assert_selector "#policy_#{recovery_period.id}_description", text: /staff help recovering security-key access/
      assert_equal "policy_#{recovery_period.id}_description policy_#{recovery_period.id}_unit",
                   find_field('Account recovery time window')['aria-describedby']
      fill_in 'Account recovery time window', with: '2'
      click_button 'Update Policies'
      assert_text 'Policies updated successfully.'
      assert_equal 16_000, Policy.find_by!(key: 'fpl_1_person').value
      assert_equal 6_000, Policy.find_by!(key: 'fpl_additional_person').value
      assert_equal @admin.id, Policy.find_by!(key: 'fpl_additional_person').policy_changes.order(:id).last.user_id
      assert_field 'Base FPL for 1 person', with: '16000'
      assert_field 'Base FPL added for each person above eight', with: '6000'
      assert_equal 2, recovery_period.reload.value
      assert_field 'Account recovery time window', with: '2'
      take_screenshot('policies-desktop-saved-values', full: true, html: true)

      page.current_window.resize_to(390, 844)
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      find_field('Account recovery time window').click
      assert_selector "#policies_#{recovery_period.id}_value:focus"
      assert_field 'Account recovery time window', with: '2'
      policy_bounds = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll(
          'section[aria-labelledby="other-system-policies-title"] input[type="number"], ' +
          'section[aria-labelledby="other-system-policies-title"] [id$="_unit"]'
        )).map(element => {
          const bounds = element.getBoundingClientRect();
          return { id: element.id, left: bounds.left, right: bounds.right };
        });
      JS
      assert_not_empty policy_bounds
      policy_bounds.each do |bounds|
        assert_operator bounds.fetch('left'), :>=, 0, bounds.fetch('id')
        assert_operator bounds.fetch('right'), :<=, 390, bounds.fetch('id')
      end
      take_screenshot('policies-narrow-labeled-editor', full: true, html: true)
      find_link('Back to Dashboard', exact: true).execute_script('this.focus()')
      assert_selector "a[href='#{admin_dashboard_path}']:focus", text: 'Back to Dashboard'
      page.driver.browser.keyboard.type(:Tab)
      assert_selector "a[href='#{admin_feature_flags_path}']:focus"
      page.driver.browser.keyboard.type(:Enter)
      assert_current_path admin_feature_flags_path
      assert_selector 'h1', text: 'Feature Flags'
      find_link('System Policies', href: admin_policies_path).click
      assert_current_path admin_policies_path
      assert_selector 'h1', text: 'System Policies', count: 1
      assert_no_text 'Content missing'
    ensure
      page.current_window.resize_to(1200, 800)
    end

    test 'a missing policy can be created separately before editing and reviewing its history' do
      Policy.find_by!(key: 'fpl_additional_person').destroy!
      visit admin_policies_path
      assert_selector '#missing-policies-title', text: 'Missing policies'
      creation = find('input[name="policy[key]"][value="fpl_additional_person"]', visible: :all).find(:xpath, 'ancestor::form')
      take_screenshot('policies-missing-policy-independent-form', full: true, html: true)
      within(creation) do
        assert_field 'Starting value', with: Baseline::Policies::DEFAULTS.fetch('fpl_additional_person').to_s
        click_button 'Create Policy'
      end
      assert_text "Policy 'fpl_additional_person' created successfully."
      assert_no_selector '#missing-policy-fpl_additional_person-value'
      fill_in 'Base FPL added for each person above eight', with: '6000'
      click_button 'Update Policies'
      assert_text 'Policies updated successfully.'
      click_link 'View Full Change History'
      wait_for_turbo
      assert_selector 'h1', text: 'Policy Change History'
      assert_no_text 'Content missing'
      assert_text '$6,000.00'
      assert_text @admin.full_name
      assert_link 'Back to Policies'
      take_screenshot('policies-created-policy-change-history', full: true, html: true)
      click_link 'Back to Policies'
      assert_selector 'h1', text: 'System Policies', count: 1
      assert_field 'Base FPL added for each person above eight', with: '6000'
    end

    test 'dated mileage rates retain invalid input and allow future changes and audited edits' do
      year = Date.current.year
      january = Date.new(year, 1, 1)
      july = Date.new(year, 7, 1)
      august = Date.new(year, 8, 1)
      future = Date.new(year + 1, 1, 1)
      assert_empty MileageRate.all
      page.current_window.resize_to(1200, 900)
      visit admin_policies_path
      within '#mileage-rates' do
        assert_text 'No mileage rates have been set.'
        within "form[action='#{admin_mileage_rates_path}']" do
          assert_equal 'MM/DD/YYYY', find_field('Effective from')['placeholder']
          assert_field 'Dollars per mile', with: ''
          fill_in 'Effective from', with: 'not-a-date'
          fill_in 'Dollars per mile', with: '0.7255'
          click_button 'Add mileage rate'
        end
      end
      within '#mileage-rates' do
        assert_selector '[role="alert"]', text: /Effective from/
        assert_selector '[role="alert"]', text: 'no more than three decimal places'
        assert_field 'Effective from', with: 'not-a-date'
        assert_field 'Dollars per mile', with: '0.7255'
        assert_equal 'true', find_field('Effective from')['aria-invalid']
        assert_includes find_field('Effective from')['aria-describedby'], 'mileage-rates-error'
      end
      assert_empty MileageRate.all
      find_by_id('mileage-rates').scroll_to(:top)
      take_screenshot('mileage-rate-invalid-date-and-price-retry', html: true)
      assert_current_path admin_policies_path

      within "#mileage-rates form[action='#{admin_mileage_rates_path}']" do
        fill_in 'Effective from', with: january.strftime('%m/%d/%Y')
        click_button 'Add mileage rate'
      end
      within '#mileage-rates' do
        assert_selector '[role="alert"]', text: 'no more than three decimal places'
        assert_field 'Effective from', with: january.strftime('%m/%d/%Y')
        assert_field 'Dollars per mile', with: '0.7255'
      end
      within "#mileage-rates form[action='#{admin_mileage_rates_path}']" do
        fill_in 'Dollars per mile', with: '0.725'
        click_button 'Add mileage rate'
      end
      assert_text 'Mileage rate saved.'
      assert_current_path admin_policies_path
      first_rate = MileageRate.find_by!(effective_on: january)
      assert_equal BigDecimal('0.725'), first_rate.dollars_per_mile
      assert_equal @admin.id, Event.find_by!(auditable: first_rate, action: 'mileage_rate_created').user_id

      within "#mileage-rates form[action='#{admin_mileage_rates_path}']" do
        fill_in 'Effective from', with: july.strftime('%m/%d/%Y')
        fill_in 'Dollars per mile', with: '0.760'
        click_button 'Add mileage rate'
      end
      assert_text 'Mileage rate saved.'
      second_rate = MileageRate.find_by!(effective_on: july)
      assert_equal BigDecimal('0.760'), second_rate.dollars_per_mile
      assert_equal 2, MileageRate.count
      find_by_id('mileage-rates').scroll_to(:top)
      take_screenshot('mileage-rates-same-year-dated-desktop', html: true)
      page.refresh
      within "#mileage-rates form[action='#{admin_mileage_rate_path(first_rate)}']" do
        assert_no_selector '[role="alert"]'
        assert_field 'Effective from', with: january.strftime('%m/%d/%Y')
        assert_field 'Dollars per mile', with: '0.725'
      end
      within "#mileage-rates form[action='#{admin_mileage_rates_path}']" do
        fill_in 'Effective from', with: future.strftime('%m/%d/%Y')
        fill_in 'Dollars per mile', with: '0.800'
        click_button 'Add mileage rate'
      end
      assert_text 'Mileage rate saved.'
      future_rate = MileageRate.find_by!(effective_on: future)
      assert_operator future_rate.effective_on, :>, Date.current
      assert_equal 3, MileageRate.count

      page.current_window.resize_to(390, 1100)
      within "#mileage-rates form[action='#{admin_mileage_rate_path(future_rate)}']" do
        find_field('Effective from').click
        assert_field 'Effective from', with: future.strftime('%m/%d/%Y')
        assert_equal 'numeric', find_field('Effective from')['inputmode']
      end
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      take_screenshot('mileage-rates-future-date-narrow', html: true)
      within "#mileage-rates form[action='#{admin_mileage_rate_path(second_rate)}']" do
        fill_in 'Effective from', with: august.strftime('%m/%d/%Y')
        fill_in 'Dollars per mile', with: '0.800'
        click_button 'Save rate'
      end
      assert_text 'Mileage rate saved.'
      assert_equal august, second_rate.reload.effective_on
      assert_equal BigDecimal('0.800'), second_rate.dollars_per_mile
      assert_equal 3, MileageRate.count
      within "#mileage-rates form[action='#{admin_mileage_rate_path(second_rate)}']" do
        assert_selector "input[name='mileage_rate[lock_version]'][value='#{second_rate.lock_version}']", visible: :all
      end
      event = Event.find_by!(auditable: second_rate, action: 'mileage_rate_updated')
      assert_equal @admin.id, event.user_id
      assert_equal [july.iso8601, august.iso8601], event.field_change_pairs.fetch('effective_on')
      within '#mileage-rates' do
        find('summary', text: 'Recent mileage rate changes').click
        assert_text july.strftime('%m/%d/%Y')
        assert_text august.strftime('%m/%d/%Y')
        assert_text '$0.760 → $0.800 per mile'
        assert_text @admin.full_name
      end
      assert_operator page.evaluate_script('document.documentElement.scrollWidth'), :<=, 390
      history = find('#mileage-rates details[open]')
      page.execute_script("arguments[0].scrollIntoView({block: 'center', behavior: 'instant'})", history)
      assert_operator history.evaluate_script('this.getBoundingClientRect().top'), :>=, 0
      assert_operator history.evaluate_script('this.getBoundingClientRect().bottom'), :<=, page.evaluate_script('window.innerHeight')
      page.current_window.resize_to(1200, 900)
      page.execute_script("window.scrollTo({top: 0, behavior: 'instant'})")
      take_screenshot('mileage-rate-effective-date-and-price-edit-history', full: true, html: true)
    ensure
      page.current_window.resize_to(1200, 800)
    end
  end
end
