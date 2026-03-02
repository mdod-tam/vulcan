# frozen_string_literal: true

module Users
  # Service to handle sending registration confirmation via email or letter
  class RegistrationConfirmationService < BaseService
    def initialize(user:, request: nil)
      @user = user
      @request = request
      super()
    end

    def call
      if email_communication?
        send_email_confirmation
      else
        send_letter_confirmation
      end

      success(nil, { method: communication_method })
    rescue StandardError => e
      failure("Failed to send registration confirmation: #{e.message}")
    end

                                                  private

    attr_reader :user, :request

    def email_communication?
      user.communication_preference.to_s == 'email'
    end

    def communication_method
      email_communication? ? 'email' : 'letter'
    end

    def send_email_confirmation
      ApplicationNotificationsMailer.registration_confirmation(user).deliver_later
    end

    def send_letter_confirmation
      Letters::TextTemplateToPdfService.new(
        template_name: 'application_notifications_registration_confirmation',
        recipient: user,
        variables: letter_template_variables
      ).queue_for_printing
    end

    def letter_template_variables
      {
        user_full_name: user.full_name,
        dashboard_url: constituent_portal_dashboard_url,
        new_application_url: apply_url,
        active_vendors_text_list: active_vendors_list,
        header_text: header_text_content,
        footer_text: footer_text_content,
        support_email: support_email
      }
    end

    def active_vendors_list
      Vendor.active.pluck(:name).join(', ')
    end

    def header_text_content
      Mailers::SharedPartialHelpers.header_text(
        title: 'Welcome to the Maryland Accessible Telecommunications Program',
        logo_url: logo_asset_url
      )
    end

    def footer_text_content
      Mailers::SharedPartialHelpers.footer_text(
        contact_email: support_email,
        website_url: website_root_url,
        show_automated_message: true
      )
    end

    def logo_asset_url
      ActionController::Base.helpers.asset_path(
        'logo.png',
        host: default_host
      )
    end

    def support_email
      Policy.get('support_email') || 'mat.program1@maryland.gov'
       end

    def website_root_url
      root_url(host: default_host)
    end

    def default_host
      Rails.application.config.action_mailer.default_url_options[:host]
    end

    # URL helpers - these need to be included for the service to work
    include Rails.application.routes.url_helpers
  end
end
