# frozen_string_literal: true

require 'test_helper'

# Every password form renders shared/_password_field. New-password fields must state the rule the
# model enforces, so the browser and the server give the same answer.
class PasswordFieldsTest < ActionDispatch::IntegrationTest
  MIN = User::PASSWORD_MIN_LENGTH.to_s

  test 'sign-up states the model minimum on the new password only' do
    get sign_up_path

    assert_select "input#user_password[minlength='#{MIN}']"
    assert_select '#user_password-hint', text: "Use at least #{MIN} characters."
    assert_select 'input#user_password[aria-describedby~=user_password-hint]'
    assert_select 'input#user_password_confirmation[minlength]', count: 0
  end

  test 'the reset form states the same minimum' do
    get edit_password_path(token: create(:user).generate_token_for(:password_reset))

    assert_select "input#password[minlength='#{MIN}']"
    assert_select '#password-hint', text: "Use at least #{MIN} characters."
    assert_select 'input#password_challenge', count: 0
  end

  test 'sign-in has no minimum length, so existing passwords still work' do
    get sign_in_path

    assert_select 'input#password-input[minlength]', count: 0
    assert_select 'label#password-input-label[for=password-input]'
  end

  test 'a short sign-up password is refused with the error tied to its field' do
    post sign_up_path, params: { user: { email: "short-#{SecureRandom.hex(3)}@example.com",
                                         password: 'elevenchars', password_confirmation: 'elevenchars',
                                         first_name: 'Short', last_name: 'Password', date_of_birth: '01/15/1990',
                                         phone: "555555#{rand(1000..9999)}", phone_type: 'voice',
                                         timezone: 'Eastern Time (US & Canada)', locale: 'en', hearing_disability: true } }

    assert_response :unprocessable_content
    assert_select '#user_password-error', text: "is too short (minimum is #{MIN} characters)"
    assert_select 'input#user_password[aria-invalid=true][aria-errormessage=user_password-error]'
  end

  test 'Spanish validation messages are translated' do
    I18n.with_locale(:es) do
      user = User.new(password: 'corta', password_confirmation: 'otra')
      user.valid?

      assert_includes user.errors.full_messages, "Contraseña tiene muy pocos caracteres (mínimo #{MIN})"
      assert_includes user.errors.full_messages, 'Confirmación de contraseña no coincide con Contraseña'
    end
  end
end
