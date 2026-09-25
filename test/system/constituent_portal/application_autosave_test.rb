# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

# Browser contract for constituent-application autosave: what reaches the draft, and what the page
# tells the constituent about it. The full form post stays authoritative; these prove the draft is
# current in between, including when the constituent leaves without leaving the field first.
class ApplicationAutosaveTest < ApplicationSystemTestCase
  include SystemTestEvidence

  WIDE = [1200, 900].freeze
  NARROW = [390, 844].freeze

  # The factory marks Hearing when no disability is set, so these start from Vision and leave
  # Hearing for the test to change.
  setup do
    @user = create(:constituent, first_name: 'Test', last_name: 'Guardian',
                                 vision_disability: true, hearing_disability: false)
  end

  test 'a new application saves while typing and Save Application continues that same draft' do
    sign_in_as(@user)
    visit new_constituent_portal_application_path

    type_in_place 'Household Size', 4
    assert_selector status_selector, text: t_autosave(:saved)
    assert_equal([4], wait_for { @user.applications.reload.pluck(:household_size).presence })
    assert_focused 'application_household_size'
    capture_both_widths('application-new-autosave-saved-en')

    # Typed and saved with no pause and no leaving the field: the form still posts to create, and
    # the server continues the draft autosave started instead of starting a second one.
    fill_in 'Annual Income', with: 45_000
    find('input[name="save_draft"]').click

    draft = @user.applications.sole
    assert_current_path constituent_portal_application_path(draft, format: :html)
    draft.reload
    assert_equal ['draft', 4, 45_000], [draft.status, draft.household_size, draft.annual_income.to_i]
    assert_no_runtime_errors
  end

  test "a dependent's new application saves to the dependent and never to the guardian" do
    dependent = create(:constituent, first_name: 'Jane', last_name: 'Dependent',
                                     vision_disability: true, hearing_disability: false)
    create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)
    sign_in_as(@user)
    visit new_constituent_portal_application_path(user_id: dependent.id)
    assert_text "New Application for #{dependent.full_name}"

    fill_in 'Household Size', with: 5
    check 'Hearing'
    assert_selector status_selector, text: t_autosave(:saved)

    draft = wait_for { Application.find_by(user: dependent, managing_guardian_id: @user.id) }
    assert_equal 5, draft.household_size
    assert(wait_for { dependent.reload.hearing_disability })
    assert_not @user.reload.hearing_disability, "the guardian's record must not change"
    assert_equal 0, Application.where(user: @user).count, 'nothing may be filed as the guardian'
    take_evidence_screenshot('application-new-dependent-autosave-saved-en', full: true, html: true)
    assert_no_runtime_errors
  end

  # Back skips turbo:before-visit. This exercises successful departure delivery, not offline recovery.
  test 'an edit typed just before Back, a link, or a full unload still reaches the draft' do
    draft = create(:application, :draft, user: @user, household_size: 2)
    sign_in_as(@user)

    page.execute_script("Turbo.visit('#{edit_constituent_portal_application_path(draft)}')")
    assert_current_path edit_constituent_portal_application_path(draft)
    type_in_place 'Household Size', 7
    assert_focused 'application_household_size'
    page.go_back
    assert_current_path constituent_portal_dashboard_path
    assert_equal 7, wait_for('Back must save the unsent edit') { draft.reload.household_size.then { |size| size if size == 7 } }
    page.go_forward
    assert_field 'Household Size', with: '7'

    type_in_place 'Household Size', 8
    click_link 'Cancel'
    assert_current_path constituent_portal_application_path(draft)
    assert_equal 8, wait_for('Cancel link must save the unsent edit') { draft.reload.household_size.then { |size| size if size == 8 } }

    visit edit_constituent_portal_application_path(draft)
    type_in_place 'Household Size', 9
    assert_focused 'application_household_size'
    accept_confirm { visit constituent_portal_dashboard_path }
    assert_equal 9, wait_for('full page visit must save the unsent edit') { draft.reload.household_size.then { |size| size if size == 9 } }
    assert_no_runtime_errors
  end

  test 'an unsaved field stays marked until corrected, and the status says so' do
    draft = create(:application, :draft, user: @user)
    sign_in_as(@user)
    visit edit_constituent_portal_application_path(draft)
    capture_status_states(draft, locale: :en, page_name: 'edit')
  end

  test 'a Spanish-preference constituent gets the status in Spanish' do
    spanish = create(:constituent, first_name: 'Sofia', last_name: 'Aplicante', locale: 'es')
    sign_in_as(spanish)
    visit new_constituent_portal_application_path
    capture_status_states(nil, locale: :es, page_name: 'new', applicant: spanish)
  end

  test 'a delayed older save cannot overwrite the value sent on departure' do
    draft = create(:application, :draft, user: @user, household_size: 2)
    sign_in_as(@user)
    visit edit_constituent_portal_application_path(draft)
    hold_older_save
    fill_in 'Household Size', with: 4
    assert(wait_for { page.evaluate_script('Boolean(window.__releaseOlderAutosave)') })
    type_in_place 'Household Size', 7
    page.execute_script("Turbo.visit('#{constituent_portal_dashboard_path}')")
    assert_current_path constituent_portal_dashboard_path
    assert_equal(7, wait_for { draft.reload.household_size.then { |value| value if value == 7 } })
    release_older_save
    assert_equal 7, draft.reload.household_size
    assert_no_runtime_errors
  end

  test 'a delayed older autosave cannot overwrite a successful Save Application' do
    draft = create(:application, :draft, user: @user, household_size: 2)
    sign_in_as(@user)
    visit edit_constituent_portal_application_path(draft)
    hold_older_save
    fill_in 'Household Size', with: 4
    assert(wait_for { page.evaluate_script('Boolean(window.__releaseOlderAutosave)') })
    type_in_place 'Household Size', 7
    find('input[name="save_draft"]').click
    assert_current_path constituent_portal_application_path(draft, format: :html)
    assert_equal 7, draft.reload.household_size
    release_older_save
    assert_equal 7, draft.reload.household_size
    assert_no_runtime_errors
  end

  test 'invalid ordering metadata does not discard a selected document on Save Application' do
    draft = create(:application, :draft, user: @user, household_size: 2)
    sign_in_as(@user)
    visit edit_constituent_portal_application_path(draft)
    page.execute_script("document.querySelector('[name=autosave_context]').value = 'invalid-context'")
    fill_in 'Household Size', with: 7
    attach_file 'application_income_proof', file_fixture('income_proof.pdf'), make_visible: true
    take_evidence_screenshot('application-save-with-invalid-ordering-and-upload', full: true, html: true)
    find('input[name="save_draft"]').click

    assert_current_path constituent_portal_application_path(draft, format: :html)
    assert_equal 7, draft.reload.household_size
    assert draft.income_proof.attached?
    assert_equal 'income_proof.pdf', draft.income_proof.filename.to_s
    take_evidence_screenshot('application-upload-saved-with-invalid-ordering', full: true, html: true)
    assert_no_runtime_errors
  end

  test 'Save Application keeps both actions disabled while its submitted snapshot is in flight' do
    draft = create(:application, :draft, user: @user, household_size: 2)
    sign_in_as(@user)
    visit edit_constituent_portal_application_path(draft)
    type_in_place 'Household Size', 7
    fill_in 'Street Address', with: '27 Saved Snapshot Road'

    entered = Queue.new
    release = Queue.new
    service = Applications::ApplicationCreator
    original = service.instance_method(:call)
    service.define_method(:call) do
      entered << true
      release.pop
      original.bind_call(self)
    end
    find('input[name="save_draft"]').click
    Timeout.timeout(10) { entered.pop }

    assert_selector 'form[data-controller~="autosave"][aria-busy="true"]'
    assert_selector 'input[name="save_draft"]:disabled'
    assert_selector 'input[name="submit_application"]:disabled'
    assert_selector '#application_household_size:disabled'
    page.execute_script(<<~JS)
      const form = document.querySelector('form[data-controller~="autosave"]')
      document.getElementById('application_household_size').dispatchEvent(new Event('input', { bubbles: true }))
      form.dispatchEvent(new CustomEvent('income-validation:validated', { bubbles: true, detail: { exceedsThreshold: false } }))
    JS
    assert_selector 'input[name="save_draft"]:disabled'
    assert_selector 'input[name="submit_application"]:disabled'
    take_evidence_screenshot('application-save-actions-disabled-in-flight', full: true, html: true)
    assert_no_runtime_errors

    release << true
    assert_current_path constituent_portal_application_path(draft, format: :html)
    assert_equal 7, draft.reload.household_size
    assert_equal '27 Saved Snapshot Road', @user.reload.physical_address_1
    assert_no_runtime_errors
  ensure
    release << true if release
    service&.define_method(:call, original) if original
  end

  test 'full unload warns while a real autosave is active and the request already has keepalive' do
    draft = create(:application, :draft, user: @user, household_size: 2)
    sign_in_as(@user)
    visit edit_constituent_portal_application_path(draft)
    entered = Queue.new
    release = Queue.new
    service = Applications::AutosaveService
    original = service.instance_method(:call)
    service.define_method(:call) do
      entered << true
      release.pop
      original.bind_call(self)
    end
    page.execute_script(<<~JS)
      const original = window.fetch
      window.fetch = (url, options) => {
        if (String(url).includes('autosave_field')) window.__autosaveKeepalive = options.keepalive
        return original(url, options)
      }
    JS
    type_in_place 'Household Size', 4
    Timeout.timeout(10) { entered.pop }
    assert_equal true, page.evaluate_script('window.__autosaveKeepalive')
    dismiss_confirm { page.execute_script('window.location.reload()') }
    assert_field 'Household Size', with: '4'
    assert_current_path edit_constituent_portal_application_path(draft)
    take_evidence_screenshot('application-autosave-stay-during-active-save', full: true, html: true)
    accept_confirm { visit constituent_portal_dashboard_path }
    release << true
    assert_current_path constituent_portal_dashboard_path
    assert_equal(4, wait_for { draft.reload.household_size.then { |value| value if value == 4 } })
    assert_no_runtime_errors
  ensure
    release << true if release
    service&.define_method(:call, original) if original
  end

  test 'replace navigation preserves history length and a first full save needs no autosave' do
    sign_in_as(@user)
    visit new_constituent_portal_application_path
    original_length = page.evaluate_script('history.length')
    page.execute_script("Turbo.visit('#{constituent_portal_dashboard_path}', { action: 'replace' })")
    assert_current_path constituent_portal_dashboard_path
    assert_equal original_length, page.evaluate_script('history.length')
    page.execute_script("Turbo.visit('#{new_constituent_portal_application_path}')")
    assert_current_path new_constituent_portal_application_path
    assert_equal 0, @user.applications.count
    find('input[name="save_draft"]').click
    draft = @user.applications.sole
    assert_current_path constituent_portal_application_path(draft, format: :html)
    assert_equal 'draft', draft.reload.status
    assert_no_runtime_errors
  end

  private

  def hold_older_save
    page.execute_script(<<~JS)
      const hold = original => (url, options) => {
        if (String(url).includes('autosave_field') && typeof options?.body === 'string' &&
            JSON.parse(options.body).field_value === '4') {
          return new Promise((resolve, reject) => {
            window.__releaseOlderAutosave = () => original(url, options).then(response => {
              window.__olderAutosaveCompleted = true
              resolve(response)
            }, reject)
          })
        }
        return original(url, options)
      }
      window.fetch = hold(window.fetch)
      window.Turbo.fetch = hold(window.Turbo.fetch)
    JS
  end

  def release_older_save
    page.execute_script('window.__releaseOlderAutosave()')
    assert(wait_for { page.evaluate_script('Boolean(window.__olderAutosaveCompleted)') })
  end

  def sign_in_as(user)
    system_test_sign_in(user)
    assert_text 'Dashboard', wait: 10
  end

  def status_selector
    '[data-autosave-target="status"][role="status"][aria-live="polite"]'
  end

  def t_autosave(key, locale: :en)
    I18n.t("applications.autosave.#{key}", locale: locale)
  end

  # Drives failed -> corrected -> saving on one page, capturing each state at both widths.
  def capture_status_states(draft, locale:, page_name:, applicant: @user)
    phone = find_field('application_alternate_contact_phone')
    phone.fill_in with: 'not a phone'
    find_field('Household Size').click
    assert_selector status_selector, text: t_autosave(:failed, locale: locale)
    assert_selector '#application_alternate_contact_phone-autosave-error', text: /invalid/i
    assert_equal 'true', phone[:'aria-invalid']
    capture_both_widths("application-#{page_name}-autosave-failed-#{locale}")

    phone.fill_in with: '2025550123'
    find_field('Household Size').click
    assert_selector status_selector, text: t_autosave(:saved, locale: locale)
    assert_no_selector '#application_alternate_contact_phone-autosave-error', text: /invalid/i
    saved = draft&.reload || applicant.applications.sole
    assert_equal '2025550123', saved.alternate_contact_phone
    capture_both_widths("application-#{page_name}-autosave-saved-#{locale}")
    assert_no_runtime_errors

    # Hold the next save in flight so its status can be seen.
    page.execute_script(<<~JS)
      const hold = (original) => (url, options) =>
        String(url).includes('autosave_field') ? new Promise(() => {}) : original(url, options)
      window.fetch = hold(window.fetch)
      if (window.Turbo) window.Turbo.fetch = hold(window.Turbo.fetch)
    JS
    fill_in 'Household Size', with: 3
    assert_selector status_selector, text: t_autosave(:saving, locale: locale)
    capture_both_widths("application-#{page_name}-autosave-saving-#{locale}")
  end

  def capture_both_widths(name)
    page.current_window.resize_to(*WIDE)
    take_evidence_screenshot("#{name}-wide", full: true, html: true)
    page.current_window.resize_to(*NARROW)
    take_evidence_screenshot("#{name}-390", full: true, html: true)
    page.execute_script('window.scrollTo(0, 0)')
    take_evidence_screenshot("#{name}-390-top")
    puts "[overflow] #{name}: scrollWidth=#{page.evaluate_script('document.documentElement.scrollWidth')}"
  ensure
    page.current_window.resize_to(*WIDE)
  end

  def wait_for(message = 'condition not met in time', timeout: 5)
    deadline = Time.current + timeout
    loop do
      value = yield
      return value if value
      raise Minitest::Assertion, message if Time.current > deadline

      sleep 0.1
    end
  end

  # Real keystrokes with focus left in the field. Capybara's fill_in fires change and blur after
  # typing, which would hide exactly the case these tests are about: leaving with an unsent edit.
  def type_in_place(label, value)
    field = find_field(label)
    page.execute_script("arguments[0].value = ''; arguments[0].focus()", field)
    field.send_keys(value.to_s)
    assert_equal value.to_s, field.value
  end

  def assert_focused(id)
    assert_equal id, page.evaluate_script('document.activeElement && document.activeElement.id')
  end

  def assert_no_runtime_errors
    assert_empty page.evaluate_script('window.__systemTestErrors')
  end
end
