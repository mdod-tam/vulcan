# frozen_string_literal: true

# Postmark delivery settings: return the API response, track opens, and do not track links.

if defined?(ActionMailer::Base)
  ActionMailer::Base.instance_eval do
    def postmark_settings
      {
        return_response: true,
        track_opens: true,
        track_links: 'none'
      }
    end
  end
end
