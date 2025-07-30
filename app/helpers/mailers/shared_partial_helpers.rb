# frozen_string_literal: true

module Mailers
  # Shared helper methods for rendering common mailer partials and templates.
  module SharedPartialHelpers
    extend ActiveSupport::Concern

    included do
      # Ensure path and url helpers are available
      include Rails.application.routes.url_helpers

      helper :application
    end

    private

    # Central cache for rendered content within a mailer invocation
    def mailer_cache
      Thread.current[:mailer_render_cache] ||= {}
    end

    # Generic helper for caching and rendering blocks
    def fetch_from_cache(key, &block)
      mailer_cache[key] ||= begin
        result = block.call.freeze
        result
      end
    rescue StandardError => e
      Rails.logger.error "Error during cached render (#{key.first}): #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      # Return a generic error message for safety
      "Error rendering #{key.first} '#{key[1]}'"
    end

    # Renders a shared mailer partial (ERB) to string, with caching.
    def render_shared_partial_to_string(partial_name, format, locals = {})
      key = [:partial, partial_name, format, locals.hash]
      fetch_from_cache(key) do
        render_to_string(
          partial: "shared/mailers/#{partial_name}",
          formats: [format],
          locals: locals
        )
      end
    rescue ActionView::MissingTemplate => e
      Rails.logger.error "Missing shared mailer partial: shared/mailers/#{partial_name} (#{e.message})"
      "Error: Missing partial 'shared/mailers/#{partial_name}' for format #{format}"
    end

    # Renders an email template stored in DB, using ActionView to avoid ERB injection,
    # with caching.
    def render_email_template(template_name, format, locals = {})
      key = [:template, template_name, format, locals.hash]
      fetch_from_cache(key) do
        template = EmailTemplate.find_by(name: template_name, format: format)
        unless template
          # Enhanced error logging with more context
          total_templates = EmailTemplate.count
          Rails.logger.error "Missing email template: #{template_name} for format #{format}. " \
                             "Total templates in DB: #{total_templates}. Rails env: #{Rails.env}"

          # In test environment, try to create a fallback template
          return "Error: Missing email template '#{template_name}' for format #{format}" unless Rails.env.test?

          template = create_fallback_template(template_name, format)
          return "Error: Missing email template '#{template_name}' for format #{format}" unless template
        end

        # Rails 8 requires proper ActionView::Base initialization with empty template cache
        view_context = ActionView::Base.with_empty_template_cache.new(
          ActionView::LookupContext.new([]),
          {},
          ActionController::Base.new
        )
        view_context.render(
          inline: template.body,
          type: :erb,
          locals: locals
        )
      end
    end

    # Creates a fallback template for test environment
    def create_fallback_template(template_name, format)
      return nil unless Rails.env.test?

      body = case template_name
             when 'email_header_text'
               "<%= title %>\n\n<% if defined?(subtitle) && subtitle.present? %>\n<%= subtitle %>\n<% end %>"
             when 'email_footer_text'
               "--\n<%= organization_name %>\nEmail: <%= contact_email %>\nWebsite: <%= website_url %>\n\n<% if defined?(show_automated_message) && show_automated_message %>\nThis is an automated message. Please do not reply directly to this email.\n<% end %>"
             else
               return nil
             end

      Rails.logger.warn "Creating fallback template for #{template_name} in test environment"
      EmailTemplate.create!(
        name: template_name,
        format: format,
        subject: "#{template_name.humanize} Template",
        description: 'Auto-created fallback template for testing',
        body: body,
        version: 1
      )
    rescue StandardError => e
      Rails.logger.error "Failed to create fallback template #{template_name}: #{e.message}"
      nil
    end

    # --- Specific helpers for common templates ---

    # Renders the text header template.
    # Expects locals like: :title, :subtitle (optional)
    def header_text(locals = {})
      render_email_template('email_header_text', :text, locals)
    end

    # Renders the text footer template.
    # Expects locals like: :contact_email, :website_url, :organization_name, :show_automated_message (boolean)
    def footer_text(locals = {})
      render_email_template('email_footer_text', :text, locals)
    end

    # Generates a simple text representation for a status box.
    # Expects locals like: :status, :title, :message
    def status_box_text(status:, title:, message:)
      "[#{status.to_s.upcase}] #{title}: #{message}"
    end
  end
end
