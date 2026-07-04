# frozen_string_literal: true

require 'application_system_test_case'

class RegistrationsTest < ApplicationSystemTestCase
  test 'phone-only paper conflict shows neutral support without creating portal account' do
    phone = '410-555-0198'
    Current.paper_context = true
    begin
      Users::Constituent.create!(
        first_name: 'Paper', last_name: 'PhoneOnlySystem',
        phone: phone,
        phone_type: 'text',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    visit sign_up_path
    fill_in 'First Name', with: 'New'
    fill_in 'Last Name', with: 'Registrant'
    fill_in 'Email Address', with: "neutral-registration-#{SecureRandom.hex(4)}@example.com"
    fill_in 'Phone Number (Optional)', with: phone
    choose 'Text/SMS'
    fill_in 'Password', with: 'password123'
    fill_in 'Confirm Password', with: 'password123'
    fill_in 'Date of Birth', with: '01/01/1990'
    select 'English', from: 'Language Preference'

    click_button 'Create Account'

    assert_current_path sign_up_path, wait: 10
    assert_text "We couldn't complete your registration."
    assert_text 'Sign in with your email address and password'
    assert_no_text 'Account created successfully'
    assert_no_text 'phone-only'
    assert_no_text 'paper record'
    assert_no_text 'has already been taken'
    take_screenshot('registration-phone-only-paper-conflict-support', html: true)
  end

  test 'password visibility toggle changes field type and updates accessibility attributes' do
    visit sign_up_path
    ensure_stimulus_loaded

    # Fill in the password fields using the warning-free method
    find_field('Password').set('password123')
    find_field('Confirm Password').set('password123')

    # Initially the password should be hidden (type="password")
    assert_equal 'password', find_field('Password')[:type]
    assert_equal 'password', find_field('Confirm Password')[:type]

    # Find and click the toggle button for the password field (initial label)
    password_toggle = first("button[data-action='visibility#togglePassword']")
    password_toggle.click

    # The password should now be visible (type="text")
    assert_equal 'text', find_field('Password')[:type]
    assert_equal 'Hide password', password_toggle['aria-label']
    assert_equal 'true', password_toggle['aria-pressed']
    assert password_toggle[:class].include?('eye-open')

    # Click again to hide
    password_toggle.click

    # The password should be hidden again (type="password")
    assert_equal 'password', find_field('Password')[:type]
    assert_equal 'Show password', password_toggle['aria-label']
    assert_equal 'false', password_toggle['aria-pressed']
    assert password_toggle[:class].include?('eye-closed')
  end

  test 'password visibility automatically reverts after timeout' do
    visit sign_up_path
    ensure_stimulus_loaded

    # Modify the timeout for testing purposes (using JavaScript)
    page.execute_script("document.querySelector('[data-visibility-timeout-value]').setAttribute('data-visibility-timeout-value', '2000')")

    # Fill in the password field
    find_field('Password').set('password123')

    # Click the toggle button
    find_field('Password').sibling("button[aria-label='Show password']").click

    # The password should be visible
    assert_equal 'text', find_field('Password')[:type]

    # Wait for the timeout
    sleep 2.5

    # The password should be hidden again
    assert_equal 'password', find_field('Password')[:type]
  end

  test 'password visibility toggle is keyboard accessible' do
    visit sign_up_path
    ensure_stimulus_loaded

    find_field('Password').set('password123')

    toggle_btn = first("button[data-action='visibility#togglePassword']")

    # Trigger click via JS to simulate keyboard activation (Enter/Space behaves as click on button)
    page.execute_script('arguments[0].click();', toggle_btn)

    assert_equal 'text', find_field('Password')[:type]

    page.execute_script('arguments[0].click();', toggle_btn)

    assert_equal 'password', find_field('Password')[:type]
  end

  test 'multiple password fields on the same page can be toggled independently' do
    visit sign_up_path
    ensure_stimulus_loaded

    # Fill in both password fields using the warning-free method
    find_field('Password').set('password123')
    find_field('Confirm Password').set('password123')

    # Toggle the first password field
    password_toggle = first("button[data-action='visibility#togglePassword']")
    password_toggle.click

    # Only the first password should be visible
    assert_equal 'text', find_field('Password')[:type]
    assert_equal 'password', find_field('Confirm Password')[:type]

    # Toggle the second password field
    confirm_toggle = find_all("button[data-action='visibility#togglePassword']").last
    confirm_toggle.click

    # Both passwords should be visible
    assert_equal 'text', find_field('Password')[:type]
    assert_equal 'text', find_field('Confirm Password')[:type]

    # Toggle the first password field back
    password_toggle.click

    # Only the second password should be visible
    assert_equal 'password', find_field('Password')[:type]
    assert_equal 'text', find_field('Confirm Password')[:type]

    # Toggle the second password field back
    confirm_toggle.click

    # Both passwords should be hidden
    assert_equal 'password', find_field('Password')[:type]
    assert_equal 'password', find_field('Confirm Password')[:type]
  end

  test 'registration optional phone type shows phone type when phone entered' do
    visit sign_up_path
    ensure_stimulus_loaded

    assert page.has_css?('[data-controller~="optional-phone-type"]', wait: 5)
    wait_until(time: 5) do
      page.evaluate_script(<<~JS)
        (function() {
          var el = document.querySelector('[data-controller~="optional-phone-type"]');
          return el && el.dataset.optionalPhoneTypeConnected === 'true';
        })();
      JS
    end

    phone_type_fields = find('[data-optional-phone-type-target="phoneTypeFields"]', visible: :all)
    assert phone_type_fields[:class].include?('hidden')
    assert_equal 'true', phone_type_fields['aria-hidden']
    assert_not page.evaluate_script("document.getElementById('phone_type_voice').required")
    assert_equal 'false', find_by_id('phone_type_voice', visible: :all)['aria-required']

    find_by_id('user_phone').set('4105550123')

    assert_no_selector('[data-optional-phone-type-target="phoneTypeFields"].hidden', wait: 5)
    assert_selector '#phone-type-hint', text: I18n.t('portal_self_service.registrations.phone_type_required')
    assert_equal 'false', find('[data-optional-phone-type-target="phoneTypeFields"]')['aria-hidden']
    assert_includes find('[data-optional-phone-type-target="phoneTypeFields"]')['aria-describedby'], 'phone-type-hint'
    assert page.evaluate_script("document.getElementById('phone_type_voice').required")
    assert_equal 'true', find_by_id('phone_type_voice', visible: :all)['aria-required']
    assert_not find_by_id('phone_type_voice', visible: :all)[:disabled]
    assert_not find_by_id('phone_type_text', visible: :all)[:disabled]
    assert_not find_by_id('phone_type_voice', visible: :all)[:checked]
    assert_not find_by_id('phone_type_text', visible: :all)[:checked]

    choose 'Text/SMS'
    assert find_by_id('phone_type_text')[:checked]
    take_screenshot('registration-optional-phone-type-visible', html: true)
  end
end
