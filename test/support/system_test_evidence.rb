# frozen_string_literal: true

# Uses Rails' own screenshot counter and paths so PNG, sidecar, and optional HTML
# stay adjacent and multiple captures in one test cannot overwrite each other.
module SystemTestEvidence
  def take_evidence_screenshot(name, full: false, selector: nil, html: false)
    raise ArgumentError, 'full and selector cannot be combined' if full && selector

    @screenshot_artifact_label = name.to_s.strip.presence
    wait_for_meaningful_page_content(timeout: 3) if respond_to?(:wait_for_meaningful_page_content)
    increment_unique

    if selector
      page.driver.browser.screenshot(path: image_path, selector: selector)
    else
      page.save_screenshot(image_path, full: full) # rubocop:disable Lint/Debugger -- intentional test evidence
    end

    File.write(html_path, page.html) if html
    write_screenshot_sidecar(image_path, label: @screenshot_artifact_label, html_saved: html)
    puts screenshot_log_message(image_path)
    image_path
  ensure
    @screenshot_artifact_label = nil
  end
end
