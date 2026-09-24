# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

class JavascriptCleanupContractTest < ApplicationSystemTestCase
  include SystemTestEvidence

  test 'paper search sends one frame request per typing burst for adults and guardians' do
    person = create(:constituent, first_name: 'Searchcontract', last_name: 'Person')
    system_test_sign_in(create(:admin))
    visit new_admin_paper_application_path
    install_request_recording

    %w[constituent guardian].each do |role|
      choose 'applicant_is_minor' if role == 'guardian'
      input_id = role == 'guardian' ? 'guardian_search_q' : 'adult_search_q'
      assert_selector "##{input_id}"
      page.driver.clear_network_traffic
      page.execute_script(<<~JS, input_id, person.first_name)
        const [id, name] = arguments;
        window.cleanupRequests = [];
        const input = document.getElementById(id);
        [name.slice(0, 3), name.slice(0, 6), name].forEach(value => {
          input.value = value;
          input.dispatchEvent(new Event('input', { bubbles: true }));
        });
      JS
      frame = role == 'guardian' ? '#guardian_search_results' : '#adult_search_results'
      within(frame) { assert_selector "li[data-user-id='#{person.id}']" }
      # Wait past the trailing debounce even when an incorrect immediate request already rendered.
      page.evaluate_async_script('setTimeout(() => arguments[0](true), 400)')
      requests = page.driver.network_traffic.map { |exchange| exchange.request.url }.select { |url| url.include?('/admin/users/search?') }
      take_evidence_screenshot("search-#{role}-results", full: true, html: true)
      assert_equal 1, requests.length, "#{role} frame requests: #{requests.inspect}"
      assert_includes requests.sole, "role=#{role}"
      within(frame) { find("li[data-user-id='#{person.id}']").click }
      selected_key = role == 'guardian' ? 'guardian_id' : 'existing_constituent_id'
      assert_selector "input[name='#{selected_key}'][value='#{person.id}']", visible: :all
      take_evidence_screenshot("search-#{role}-selected", full: true, html: true)

      picker = role == 'guardian' ? '#guardian-info-section' : '[data-controller="adult-picker"]'
      within(picker) { click_button 'Change Selection' }
      fill_in input_id, with: 'NoMatchingPerson9876'
      within(frame) { assert_text 'No users found matching your search.' }
      take_evidence_screenshot("search-#{role}-empty-results", full: true, html: true)
      page.driver.clear_network_traffic
      page.execute_script(<<~JS, input_id)
        const input = document.getElementById(arguments[0]);
        input.value = 'obsolete';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.closest('[data-controller="admin-user-search"]').querySelector('[data-action="click->admin-user-search#clearSearchAndShowForm"]').click();
      JS
      page.evaluate_async_script('setTimeout(() => arguments[0](true), 400)')
      assert_empty(page.driver.network_traffic.select { |exchange| exchange.request.url.include?('/admin/users/search?') })
      assert_field input_id, with: ''
      fill_in input_id, with: person.first_name
      within(frame) { find("li[data-user-id='#{person.id}']").click }
      assert_selector "input[name='#{selected_key}'][value='#{person.id}']", visible: :all
      assert_empty page.evaluate_script('window.__systemTestErrors')
    end
  end

  private

  def install_request_recording
    page.execute_script(<<~JS)
      window.cleanupRequests = [];
      const originalFetch = window.fetch;
      window.fetch = function(input, options) {
        window.cleanupRequests.push(String(input instanceof Request ? input.url : input));
        return originalFetch.call(this, input, options);
      };
    JS
  end
end
