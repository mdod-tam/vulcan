# frozen_string_literal: true

if Rails.env.test?
  require 'capybara/rails'
  require 'capybara/cuprite'
  require 'socket' # Required for IPSocket

  # Configure Cuprite driver
  Capybara.register_driver(:cuprite) do |app|
    Capybara::Cuprite::Driver.new(
      app,
      window_size: [1440, 900],
      # See additional options for Docker: https://github.com/rubycdp/cuprite?tab=readme-ov-file#docker
      browser_options: ENV['DOCKER'] ? { 'no-sandbox' => nil } : {},
      # Increase Chrome startup wait time (required for CI)
      process_timeout: 15,
      # Enable debugging: https://github.com/rubycdp/cuprite?tab=readme-ov-file#debugging
      inspector: true,
      # Allow Cuprite to capture JS errors and convert to Ruby exceptions
      js_errors: true,
      # Enable headless mode by default but allow override via HEADLESS=0
      headless: %w[0 false].exclude?(ENV.fetch('HEADLESS', 'true').downcase),
      # Slow down interactions for better visibility when not headless
      slowmo: ENV['SLOWMO']&.to_f
    )
  end

  # Use Cuprite driver for all tests
  Capybara.default_driver = :cuprite
  Capybara.javascript_driver = :cuprite

  # Disable CSS transitions and animations for faster, more reliable tests
  Capybara.disable_animation = true

  # Configuration for system tests
  Capybara.configure do |config|
    # Network settings - use localhost for stability
    config.server_host = '127.0.0.1' # Use localhost instead of 0.0.0.0 for stability
    # Don't set app_host unless doing subdomain testing (Stack Overflow best practice)
    # config.app_host = "http://#{IPSocket.getaddress(Socket.gethostname)}" if ENV['CI']

    # Configure server for system tests
    config.server = :puma, { Silent: true }

    # Use dynamic port allocation for parallel testing (avoids port conflicts)
    config.server_port = nil # Let Capybara choose available ports

    # Reasonable default wait time (seconds) - longer in CI
    config.default_max_wait_time = ENV['CI'] ? 15 : 10

    # Input and interaction settings
    # Avoid passing Node#set options to Cuprite (it logs warnings and ignores them).
    # Use targeted helpers like safe_fill_in / cuprite_fill_in instead of global clear options.
    config.automatic_label_click = true
    config.automatic_reload = true # Auto-refind stale nodes after DOM changes

    # Enable aria-label support
    config.enable_aria_label = true

    # Configure test_id for cleaner element finding (following writeup best practices)
    config.test_id = 'data-testid'

    # Save path for Capybara screenshots
    config.save_path = Rails.root.join('tmp/capybara')
  end
end
