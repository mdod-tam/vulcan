# frozen_string_literal: true

module Admin
  class EmailTemplatesController < Admin::BaseController
    include Pagy::Backend # Include Pagy for pagination

    before_action :set_template,
                  only: %i[show edit update new_test_email send_test toggle_disabled mark_synced create_counterpart
                           preview]
    before_action :load_locale_templates, only: %i[show edit update preview]

    # GET /admin/email_templates
    def index
      # Fetch all templates, including both HTML and text formats
      # Group by name, but grab just one locale variant per name as the main representation.
      # The show/edit views will handle loading both variants together.
      templates = EmailTemplate.where(locale: 'en').or(EmailTemplate.where(locale: 'es'))
                               .select('DISTINCT ON (name, format) *')
                               .order(:name, :format, :locale)

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
      end}, Total: #{templates.length}"
    end

    # GET /admin/email_templates/:id
    def show
      # @email_template is set by before_action
      # @template_definition is set by before_action

      # Expensive computation in controller
      @en_sample_data = view_context.sample_data_for_template(
        @email_template.name,
        locale: 'en',
        subject: @en_template&.subject,
        format: @email_template.format
      )
      @es_sample_data = view_context.sample_data_for_template(
        @email_template.name,
        locale: 'es',
        subject: @es_template&.subject,
        format: @email_template.format
      )

      if @en_template
        begin
          @en_rendered_subject, @en_rendered_body = @en_template.render(**@en_sample_data)
        rescue StandardError => e
          friendly_error = helpers.template_render_error_message(e)
          @en_rendered_subject = 'Preview unavailable'
          @en_rendered_body = friendly_error
        end
      end

      if @es_template
        begin
          @es_rendered_subject, @es_rendered_body = @es_template.render(**@es_sample_data)
        rescue StandardError => e
          friendly_error = helpers.template_render_error_message(e)
          @es_rendered_subject = 'Preview unavailable'
          @es_rendered_body = friendly_error
        end
      end

      log_audit_event('email_template_viewed')
    end

    # GET /admin/email_templates/:id/new_test_email
    def new_test_email
      # @email_template is set by before_action
      # @template_definition is set by before_action

      # Get sample data and render the template with it for preview
      sample_data = view_context.sample_data_for_template(
        @email_template.name,
        locale: @email_template.locale,
        subject: @email_template.subject,
        format: @email_template.format
      )
      @rendered_subject, @rendered_body = @email_template.render(**sample_data)

      @test_email_form = ::Admin::TestEmailForm.new(
        email: current_user.email,
        template_id: @email_template.id
      )
    rescue StandardError => e
      Rails.logger.error("Failed to render template preview: #{e.message}")
      friendly_error = helpers.template_render_error_message(e)
      @rendered_subject = 'Preview unavailable'
      @rendered_body = friendly_error
      @test_email_form = ::Admin::TestEmailForm.new(
        email: current_user.email,
        template_id: @email_template.id
      )
    end

    # GET /admin/email_templates/:id/edit
    def edit
      # @email_template is set by before_action
      # @template_definition is set by before_action

      # Expensive computation done in controller for form preview
      @sample_data = view_context.sample_data_for_template(@email_template.name, format: @email_template.format)
      @counterpart_template = counterpart_template
    end

    # PATCH/PUT /admin/email_templates/:id
    def update
      # @email_template is set by before_action
      # @template_definition is set by before_action
      target_template = template_for_locale(params[:locale].presence || @email_template.locale)
      target_locale = target_template&.locale&.upcase || params[:locale].to_s.upcase

      unless target_template
        redirect_to edit_admin_email_template_path(@email_template),
                    alert: "Could not find #{target_locale} template for this template pair."
        return
      end

      if update_template(target_template)
        @email_template = target_template
        log_template_update_event
        redirect_to edit_admin_email_template_path(target_template), notice: "#{target_locale} template updated."
      else
        render_update_failure(target_template, target_locale)
      end
    rescue ArgumentError => e
      raise unless invalid_syntax_argument?(e)

      target_template ||= @email_template
      target_locale ||= target_template.locale.to_s.upcase
      target_template.errors.add(:syntax, 'Choose a valid placeholder style.')
      render_update_failure(target_template, target_locale)
    end

    # PATCH /admin/email_templates/:id/preview
    def preview
      target_template = template_for_locale(params[:locale].presence || @email_template.locale)

      unless target_template
        render_draft_preview(template: @email_template,
                             error_message: 'Could not find this locale template for preview.')
        return
      end

      target_template.assign_attributes(email_template_params)

      if target_template.valid?
        sample_data = view_context.sample_data_for_email_template(target_template,
                                                                  locale: target_template.locale,
                                                                  subject: target_template.subject)
        rendered_subject, rendered_body = target_template.render(**sample_data)
        render_draft_preview(template: target_template,
                             rendered_subject: rendered_subject,
                             rendered_body: rendered_body)
      else
        render_draft_preview(template: target_template,
                             error_message: helpers.template_render_error_message(target_template.errors.full_messages))
      end
    rescue ArgumentError => e
      raise unless invalid_syntax_argument?(e)

      target_template ||= @email_template
      target_template.errors.add(:syntax, 'Choose a valid placeholder style.')
      render_draft_preview(template: target_template,
                           error_message: helpers.template_validation_error_messages(target_template.errors.full_messages).join(', '))
    rescue StandardError => e
      Rails.logger.error("Failed to render draft template preview: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      render_draft_preview(template: target_template || @email_template,
                           error_message: helpers.template_render_error_message(e))
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

    # PATCH /admin/email_templates/:id/toggle_disabled
    def toggle_disabled
      new_state = !@email_template.enabled

      if @email_template.update(enabled: new_state, updated_by: current_user)
        action = new_state ? 'enabled' : 'disabled'
        log_audit_event('email_template_toggled', enabled: new_state)
        redirect_to admin_email_templates_path,
                    notice: "Email template '#{@email_template.name}' has been #{action}."
      else
        redirect_to admin_email_templates_path,
                    alert: "Failed to update template: #{@email_template.errors.full_messages.join(', ')}"
      end
    end

    # PATCH /admin/email_templates/:id/mark_synced
    def mark_synced
      @email_template.update!(locale_needs_sync: false)
      log_audit_event('email_template_marked_synced')
      redirect_to admin_email_template_path(@email_template),
                  notice: 'Template marked as synced.'
    end

    # POST /admin/email_templates/:id/create_counterpart
    def create_counterpart
      target_locale = counterpart_locale_for(@email_template.locale)
      existing_template = counterpart_template

      if existing_template
        redirect_to edit_admin_email_template_path(@email_template),
                    notice: "#{target_locale.upcase} template already exists."
        return
      end

      created_template = EmailTemplate.new(
        name: @email_template.name,
        format: @email_template.format,
        locale: target_locale,
        subject: @email_template.subject,
        body: @email_template.body,
        description: @email_template.description,
        syntax: @email_template.render_syntax,
        variables: @email_template.variables,
        enabled: @email_template.enabled,
        updated_by: current_user
      )

      if created_template.save
        redirect_to edit_admin_email_template_path(@email_template),
                    notice: "Created #{target_locale.upcase} template from #{@email_template.locale.upcase}."
      else
        redirect_to edit_admin_email_template_path(@email_template),
                    alert: "Failed to create #{target_locale.upcase} template: #{created_template.errors.full_messages.join(', ')}"
      end
    end

    # PATCH /admin/email_templates/bulk_disable
    def bulk_disable
      count = bulk_update_enabled_state(enabled: false)
      AuditEventService.log(
        actor: current_user,
        action: 'email_templates_bulk_disabled',
        auditable: current_user,
        metadata: { count: count }
      )
      redirect_to admin_email_templates_path,
                  notice: "All #{count} email templates have been disabled."
    end

    # PATCH /admin/email_templates/bulk_enable
    def bulk_enable
      count = bulk_update_enabled_state(enabled: true)
      AuditEventService.log(
        actor: current_user,
        action: 'email_templates_bulk_enabled',
        auditable: current_user,
        metadata: { count: count }
      )
      redirect_to admin_email_templates_path,
                  notice: "All #{count} email templates have been enabled."
    end

    private

    def capture_original_values(template)
      {
        subject: template.subject,
        body: template.body,
        description: template.description,
        syntax: template.render_syntax
      }
    end

    def update_template(template)
      @original_values = capture_original_values(template)
      template.update(email_template_params.merge(updated_by: current_user))
    end

    def log_template_update_event
      log_audit_event('email_template_updated', changes: template_changes)
    end

    def template_changes
      changes = {
        subject: { from: @original_values[:subject], to: @email_template.subject },
        body: { from: @original_values[:body], to: @email_template.body },
        description: { from: @original_values[:description], to: @email_template.description },
        syntax: { from: @original_values[:syntax], to: @email_template.render_syntax }
      }
      changes.reject { |_key, change| change[:from] == change[:to] }
    end

    def render_draft_preview(template:, rendered_subject: nil, rendered_body: nil, error_message: nil)
      locale_code = template.locale.to_s.downcase

      render partial: 'admin/email_templates/draft_preview',
             locals: {
               frame_id: "template-preview-#{locale_code}",
               template: template,
               rendered_subject: rendered_subject,
               rendered_body: rendered_body,
               error_message: error_message
             },
             status: error_message.present? ? :unprocessable_content : :ok
    end

    def render_update_failure(target_template, target_locale)
      if target_template.locale == 'en'
        @en_template = target_template
      else
        @es_template = target_template
      end

      # Re-prepare sample data for form re-render on validation failure
      @sample_data = view_context.sample_data_for_template(target_template.name, format: target_template.format)
      @counterpart_template = counterpart_template
      friendly_errors = helpers.template_validation_error_messages(target_template.errors.full_messages)
      flash.now[:alert] = "Failed to update #{target_locale} template: #{friendly_errors.join(', ')}"
      render :edit, status: :unprocessable_content
    end

    def invalid_syntax_argument?(error)
      error.message.match?(/is not a valid syntax/)
    end

    def bulk_update_enabled_state(enabled:)
      scope = enabled ? EmailTemplate.disabled_templates : EmailTemplate.enabled
      count = 0

      EmailTemplate.transaction do
        scope.find_each do |template|
          template.update!(enabled: enabled, updated_by: current_user)
          count += 1
        end
      end

      count
    end

    def set_template
      @email_template = EmailTemplate.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_email_templates_path, alert: t('alerts.e_template_not_found')
    end

    def email_template_params
      params.expect(email_template: %i[subject body description syntax])
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
        email_template_syntax: @email_template.render_syntax,
        timestamp: Time.current.iso8601
      }

      AuditEventService.log(
        actor: current_user,
        action: action,
        auditable: @email_template,
        metadata: base_metadata.merge(additional_metadata)
      )
    end

    def send_test_email
      sample_data = helpers.sample_data_for_template(
        @email_template.name,
        locale: @email_template.locale,
        subject: @email_template.subject,
        format: @email_template.format
      )
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
      friendly_error = helpers.template_render_error_message(error)
      @rendered_subject = 'Preview unavailable'
      @rendered_body = friendly_error

      flash.now[:alert] = "Failed to send test email: #{friendly_error}"
      render :new_test_email, status: :unprocessable_content
    end

    def counterpart_template
      target_locale = counterpart_locale_for(@email_template.locale)
      EmailTemplate.find_by(
        name: @email_template.name,
        format: @email_template.format,
        locale: target_locale
      )
    end

    def load_locale_templates
      templates_by_locale = EmailTemplate.where(name: @email_template.name, format: @email_template.format, locale: %w[en es])
                                         .index_by(&:locale)
      @en_template = templates_by_locale['en']
      @es_template = templates_by_locale['es']
    end

    def template_for_locale(locale)
      locale.to_s == 'es' ? @es_template : @en_template
    end

    def counterpart_locale_for(locale)
      locale.to_s == 'en' ? 'es' : 'en'
    end
  end
end
