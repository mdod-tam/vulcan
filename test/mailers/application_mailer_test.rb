require "test_helper"

class ApplicationMailerTest < ActionMailer::TestCase
  test "host_url is set correctly in development" do
    Rails.stub :env, ActiveSupport::StringInquirer.new("development") do
      # Create a mailer instance and directly test the set_default_host_url method
      mailer = ApplicationMailer.new
      mailer.send(:set_default_host_url)

      # Verify the host URL is set to localhost:3000 in development
      assert_equal "localhost:3000", mailer.instance_variable_get(:@host_url)
    end
  end

  test "host_url is set correctly in production with missing MAILER_HOST" do
    Rails.stub :env, ActiveSupport::StringInquirer.new("production") do
      # Store the original MAILER_HOST value
      original_host = ENV["MAILER_HOST"]

      begin
        # Temporarily unset MAILER_HOST
        ENV["MAILER_HOST"] = nil

        # Create a mailer instance and directly test the set_default_host_url method
        mailer = ApplicationMailer.new
        mailer.send(:set_default_host_url)

        # Verify the host URL is set to the default Heroku URL
        assert_equal "morning-dawn-84330-f594822dd77d.herokuapp.com", mailer.instance_variable_get(:@host_url)
      ensure
        # Restore the original MAILER_HOST value
        ENV["MAILER_HOST"] = original_host
      end
    end
  end

  test "host_url is set correctly in production with MAILER_HOST" do
    Rails.stub :env, ActiveSupport::StringInquirer.new("production") do
      # Store the original MAILER_HOST value
      original_host = ENV["MAILER_HOST"]

      begin
        # Set a test MAILER_HOST value
        ENV["MAILER_HOST"] = "test-host.example.com"

        # Create a mailer instance and directly test the set_default_host_url method
        mailer = ApplicationMailer.new
        mailer.send(:set_default_host_url)

        # Verify the host URL is set to the MAILER_HOST value
        assert_equal "test-host.example.com", mailer.instance_variable_get(:@host_url)
      ensure
        # Restore the original MAILER_HOST value
        ENV["MAILER_HOST"] = original_host
      end
    end
  end
end
