# frozen_string_literal: true

require 'test_helper'

class PagesControllerTest < ActionDispatch::IntegrationTest
  test 'the public vendor terms page explains its initial unpublished state' do
    get terms_path

    assert_response :success
    assert_select 'h1', I18n.t('vendor_onboarding.terms.title')
    assert_select 'p', I18n.t('vendor_onboarding.terms.unavailable')
  end

  test 'vendor terms publication requires content and the unavailable guidance is localized' do
    VendorTerms.stubs(:published?).returns(true)
    VendorTerms.stubs(:agreement).returns('')

    get terms_path(locale: 'es')

    assert_response :success
    assert_select 'section[lang="es"] p', I18n.t('vendor_onboarding.terms.unavailable', locale: :es)

    VendorTerms.stubs(:agreement).returns('Test-only approved vendor agreement.')
    get terms_path

    assert_response :success
    assert_select 'p', 'Test-only approved vendor agreement.'
    assert_not_includes response.body, I18n.t('vendor_onboarding.terms.unavailable')
  end

  test 'pages controller actions exist' do
    assert defined?(PagesController), 'PagesController should be defined'

    %i[help how_it_works eligibility apply contact].each do |action|
      assert_respond_to PagesController.new, action, "PagesController should respond to '#{action}'"
    end

    assert_recognizes({ controller: 'pages', action: 'help' }, '/help')
    assert_recognizes({ controller: 'pages', action: 'how_it_works' }, '/how_it_works')
    assert_recognizes({ controller: 'pages', action: 'eligibility' }, '/eligibility')
    assert_recognizes({ controller: 'pages', action: 'apply' }, '/apply')
    assert_recognizes({ controller: 'pages', action: 'contact' }, '/contact')

    %w[help how_it_works eligibility apply contact].each do |view|
      assert Rails.root.join("app/views/pages/#{view}.html.erb").exist?,
             "app/views/pages/#{view}.html.erb should exist"
    end
  end

  # Placeholders: these pages have no content tests yet.

  test 'should get help page' do
    skip 'No page content test yet'
  end

  test 'should get how it works page' do
    skip 'No page content test yet'
  end

  test 'should get contact page' do
    skip 'No page content test yet'
  end

  test 'should get apply page' do
    skip 'No page content test yet'
  end

  test 'should get eligibility page' do
    skip 'No page content test yet'
  end
end
