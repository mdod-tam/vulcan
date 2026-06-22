# frozen_string_literal: true

require 'application_system_test_case'

class BrowserTest < ApplicationSystemTestCase
  test 'Chrome for Testing is correctly configured' do
    # Visit the home page to check if Chrome for Testing works
    visit root_path

    # Take a screenshot to verify the browser is running
    screenshot_path = take_screenshot('browser-home', html: true)
    sidecar = screenshot_sidecar_for(screenshot_path)

    assert_equal 'browser-home', sidecar.fetch('label')
    assert_equal true, sidecar.fetch('artifact_usable_for_llm_qa')
    assert_empty sidecar.fetch('unusable_reasons')
    assert_path_exists sidecar.fetch('screenshot_path')
    assert_path_exists sidecar.fetch('html_path')

    # If we got this far, Chrome for Testing is working!
    assert true, 'Chrome for Testing is configured correctly'
  end

  test 'blank browser screenshots are marked unusable for LLM QA' do
    visit 'about:blank'

    screenshot_path = take_screenshot('about-blank-check')
    sidecar = screenshot_sidecar_for(screenshot_path)

    assert_equal 'about-blank-check', sidecar.fetch('label')
    assert_equal false, sidecar.fetch('artifact_usable_for_llm_qa')
    assert_includes sidecar.fetch('unusable_reasons'), 'about_blank_url'
    assert_includes sidecar.fetch('unusable_reasons'), 'empty_body_text'
  end

  private

  def screenshot_sidecar_for(screenshot_path)
    JSON.parse(File.read(screenshot_path.sub(/\.png\z/, '.json')))
  end
end
