# frozen_string_literal: true

module Admin
  class EmailTemplatesController < Admin::BaseController
    include Pagy::Backend # Include Pagy for pagination

    before_action :set_template, only: %i[show edit update new_test_email send_test]
    before_action :load_template_definition, only: %i[show edit update new_test_email] # Load definition for relevant actions

    # GET /admin/email_templates
    def index
      # Fetch all templates, including both HTML and text formats
      # Using a custom query to ensure we get all templates regardless of format
      templates = EmailTemplate.all

      # Group templates by name for better organization
      grouped_templates = templates.group_by(&:name).map do |_name, group|
        # Sort within each group - html first, then text
        group.sort_by(&:format)
      end.flatten

      # Apply pagination to the sorted list - use pagy_array for Array objects
      @pagy, @email_templates = pagy_array(
        grouped_templates,
        items: 50
      )

      # Log the count of templates by format for diagnostics
      Rails.logger.info "Templates loaded - HTML: #{templates.count(&:html?)}, TEXT: #{templates.count do |t|
        t.format.to_s == 'text'
      end}, Total: #{templates.count}"
    end

    # GET /admin/email_templates/:id
    def show
      # @email_template is set by before_action
      # @template_definition is set by before_action

      # Expensive computation in controller
      @sample_data = view_context.sample_data_for_template(@email_template.name)

      # Render template with sample data for preview
      begin
        @rendered_subject, @rendered_body = @email_template.render(**@sample_data)
      rescue StandardError => e
        @rendered_subject = "Error rendering subject: #{e.message}"
        @rendered_body = "Error rendering template: #{e.message}"
      end

      log_audit_event('email_template_viewed')
    end

    # GET /admin/email_templates/:id/new_test_email
    def new_test_email
      # @email_template is set by before_action
      # @template_definition is set by before_action

      # Get sample data and render the template with it for preview
      sample_data = view_context.sample_data_for_template(@email_template.name)
      @rendered_subject, @rendered_body = @email_template.render(**sample_data)

      @test_email_form = ::Admin::TestEmailForm.new(
        email: current_user.email,
        template_id: @email_template.id
      )
    rescue StandardError => e
      Rails.logger.error("Failed to render template preview: #{e.message}")
      @rendered_subject = "Error rendering subject: #{e.message}"
      @rendered_body = "Error rendering template: #{e.message}"
    end

    # GET /admin/email_templates/:id/edit
    def edit
      # @email_template is set by before_action
      # @template_definition is set by before_action

      # Expensive computation done in controller for form preview
      @sample_data = view_context.sample_data_for_template(@email_template.name)
    end

    # PATCH/PUT /admin/email_templates/:id
    def update
      # @email_template is set by before_action
      # @template_definition is set by before_action

      @original_values = capture_original_values

      if @email_template.update(email_template_params.merge(updated_by: current_user))
        log_template_update_event
        redirect_to admin_email_template_path(@email_template), notice: t('.e_template_update_pass')
      else
        # Re-prepare sample data for form re-render on validation failure
        @sample_data = view_context.sample_data_for_template(@email_template.name)
        flash.now[:alert] = "Failed to update template: #{@email_template.errors.full_messages.join(', ')}"
        render :edit, status: :unprocessable_content
      end
    end

    # POST /admin/email_templates/:id/send_test
    def send_test
      @test_email_form = ::Admin::TestEmailForm.new(test_email_params)

      if @test_email_form.valid?
        send_test_email
        log_audit_event('email_template_test_sent', test_email_metadata)
        redirect_to admin_email_template_path(@email_template),
                    notice: "Test email sent successfully to #{@test_email_form.email}."
      else
        handle_invalid_form
      end
    rescue StandardError => e
      handle_test_email_error(e)
    end

    private

    def capture_original_values
      {
        subject: @email_template.subject,
        body: @email_template.body
      }
    end

    def log_template_update_event
      log_audit_event('email_template_updated', changes: template_changes)
    end

    def template_changes
      changes = {
        subject: { from: @original_values[:subject], to: @email_template.subject },
        body: { from: @original_values[:body], to: @email_template.body }
      }
      changes.reject { |_key, change| change[:from] == change[:to] }
    end

    def set_template
      @email_template = EmailTemplate.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_email_templates_path, alert: t('alerts.e_template_not_found')
    end

    # Load the definition from the constant based on the template name
    def load_template_definition
      # Try loading with both symbol and string keys since the hash may have string keys in some scenarios
      @template_definition = EmailTemplate::AVAILABLE_TEMPLATES[@email_template.name.to_sym] ||
                             EmailTemplate::AVAILABLE_TEMPLATES[@email_template.name.to_s] ||
                             {}

      # If we don't have a description in the template definition but the template has one,
      # use the template's description
      return unless @template_definition[:description].blank? && @email_template.description.present?

      @template_definition[:description] = @email_template.description
    end

    def email_template_params
      params.expect(email_template: %i[subject body description])
    end

    def test_email_params
      params.expect(admin_test_email_form: %i[email template_id])
    end

    # Shared audit logging method
    def log_audit_event(action, additional_metadata = {})
      base_metadata = {
        email_template_id: @email_template.id,
        email_template_name: @email_template.name,
        email_template_format: @email_template.format,
        timestamp: Time.current.iso8601
      }

      Event.create!(
        user: current_user,
        action: action,
        metadata: base_metadata.merge(additional_metadata)
      )
    end

    def send_test_email
      sample_data = helpers.sample_data_for_template(@email_template.name)
      rendered_subject, rendered_body = @email_template.render(**sample_data)

      AdminTestMailer.with(
        user: current_user,
        recipient_email: @test_email_form.email,
        template_name: @email_template.name,
        subject: rendered_subject,
        body: rendered_body,
        format: @email_template.format
      ).test_email.deliver_later
    end

    def test_email_metadata
      { recipient_email: @test_email_form.email }
    end

    def handle_invalid_form
      flash.now[:alert] = "Invalid email address: #{@test_email_form.errors.full_messages.join(', ')}"
      render :new_test_email, status: :unprocessable_content
    end

    def handle_test_email_error(error)
      Rails.logger.error("Failed to send test email for template #{@email_template.id}: #{error.message}")
      Rails.logger.error(error.backtrace.join("\n"))

      @test_email_form = ::Admin::TestEmailForm.new(
        email: params.dig(:admin_test_email_form, :email) || current_user.email,
        template_id: @email_template.id
      )

      flash.now[:alert] = "Failed to send test email: #{error.message}. Check sample data and template syntax."
      render :new_test_email, status: :unprocessable_content
    end
  end
end
