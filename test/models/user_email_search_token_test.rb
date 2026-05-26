# frozen_string_literal: true

require 'test_helper'

class UserEmailSearchTokenTest < ActiveSupport::TestCase
  test 'creates HMAC email search tokens for normalized email pieces' do
    user = create(:constituent, email: 'Alex.Smith+Portal@Example.COM')

    assert_not_empty user.email_search_tokens.reload
    assert_includes User.with_email_search_match('alex.smith+portal@example.com'), user
    assert_includes User.with_email_search_match('alex'), user
    assert_includes User.with_email_search_match('alex.smith+portal@'), user
    assert_includes User.with_email_search_match('alex.smith+portal@exam'), user
    assert_includes User.with_email_search_match('smit'), user
    assert_includes User.with_email_search_match('port'), user
    assert_includes User.with_email_search_match('example.com'), user
    assert_includes User.with_email_search_match('exam'), user
    assert_not_includes user.email_search_tokens.pluck(:token_digest).join, 'alex'
  end

  test 'refreshes email search tokens when email changes' do
    user = create(:constituent, email: 'old.anchor@example.com')

    assert_includes User.with_email_search_match('anchor'), user

    user.update!(email: 'new.signal@example.com')

    assert_not_includes User.with_email_search_match('anchor'), user
    assert_includes User.with_email_search_match('signal'), user
  end

  test 'indexes dependent email' do
    dependent = create(:constituent, email: 'system.dependent@example.com',
                                     dependent_email: 'dependent.contact@example.com')

    assert_includes User.with_email_search_match('contact'), dependent
  end

  test 'matches dependents whose effective email falls back to guardian email' do
    guardian = create(:constituent, email: 'guardian.fallback@example.com')
    dependent = create(:constituent, email: 'dependent.system@example.com', dependent_email: nil)
    create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

    matches = User.with_email_search_match('fallback')

    assert_includes matches, guardian
    assert_includes matches, dependent
  end
end
