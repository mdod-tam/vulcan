# frozen_string_literal: true

module Admin
  module EmailTemplatesHelper # rubocop:disable Metrics/ModuleLength
    LAYOUT_PLACEHOLDER_NAMES = %w[header_text footer_text header_html footer_html].freeze

    def template_locale_label(locale)
      case locale.to_s
      when 'en' then 'English (EN)'
      when 'es' then 'Spanish (ES)'
      else locale.to_s.upcase
      end
    end

    def counterpart_locale(locale)
      locale.to_s == 'en' ? 'es' : 'en'
    end

    def template_last_updated_text(template)
      return 'Last updated: unavailable' unless template&.updated_at

      editor_name = template.updated_by&.full_name.presence || 'System'
      formatted_time = template.updated_at.strftime('%B %d, %Y at %I:%M %p')
      "Last updated (#{template.locale.to_s.upcase}): #{formatted_time} by #{editor_name}"
    end

    def template_sync_status(template)
      template&.locale_needs_sync? ? 'Needs sync' : 'In sync'
    end

    def template_sync_badge_classes(template)
      if template&.locale_needs_sync?
        'inline-flex items-center rounded-full bg-amber-100 px-3 py-1 text-xs font-medium text-amber-800'
      else
        'inline-flex items-center rounded-full bg-emerald-100 px-3 py-1 text-xs font-medium text-emerald-800'
      end
    end

    def email_template_liquid_enabled?
      FeatureFlag.enabled?(:email_template_liquid)
    end

    def template_syntax_label(template_or_syntax)
      syntax = template_or_syntax.respond_to?(:render_syntax) ? template_or_syntax.render_syntax : template_or_syntax.to_s

      case syntax
      when 'liquid'
        'Liquid'
      else
        'Standard'
      end
    end

    def template_syntax_badge_classes(template)
      if template&.render_syntax == 'liquid'
        'inline-flex items-center rounded-full bg-cyan-100 px-3 py-1 text-xs font-medium text-cyan-800'
      else
        'inline-flex items-center rounded-full bg-gray-100 px-3 py-1 text-xs font-medium text-gray-800'
      end
    end

    def email_template_syntax_options(template)
      options = [['Standard (%<name>s)', 'legacy_percent']]
      return options unless template&.text?

      options << ['Liquid ({{ name }})', 'liquid'] if email_template_liquid_enabled? || template&.render_syntax == 'liquid'
      options
    end

    def variable_placeholder_for(template, variable, syntax: nil)
      selected_syntax = syntax.presence || template.render_syntax
      selected_syntax.to_s == 'liquid' ? "{{ #{variable} }}" : "%<#{variable}>s"
    end

    def variable_display_label(variable)
      variable.to_s.tr('._', ' ').squish.titleize
    end

    def variable_option_label(template, variable, syntax: nil)
      "#{variable_display_label(variable)} - #{variable_placeholder_for(template, variable, syntax: syntax)}"
    end

    def placeholder_style_help_classes(style, template)
      visible = template.render_syntax == style.to_s
      classes = ['rounded-md border px-3 py-2 text-sm']
      classes.unshift('hidden') unless visible
      classes.join(' ')
    end

    def standard_placeholder_style_help_classes(template)
      "#{placeholder_style_help_classes(:legacy_percent, template)} border-gray-200 bg-gray-50 text-gray-600"
    end

    def liquid_placeholder_style_help_classes(template)
      "#{placeholder_style_help_classes(:liquid, template)} border-cyan-200 bg-cyan-50 text-cyan-900"
    end

    def display_template_body(template)
      template.body.to_s.lines.map { |line| display_template_body_line(line) }.join
    end

    def template_render_error_message(error_or_messages)
      messages = Array(error_or_messages.respond_to?(:message) ? error_or_messages.message : error_or_messages)
                 .map(&:to_s)
      message = messages.join(', ')

      return message if admin_actionable_template_error?(message)

      return 'This template has a placeholder problem. Use Insert Variable, then preview again.' if template_placeholder_error?(message)

      'This template could not be previewed. Check the placeholders and try again.'
    end

    def template_validation_error_messages(messages)
      Array(messages).map { |message| template_validation_error_message(message) }.uniq
    end

    def template_validation_error_message(message)
      cleaned_message = message.to_s.sub(/\A(?:Base|Body|Subject|Syntax) /, '')

      return 'This template has a placeholder problem. Use Insert Variable, then save again.' if invalid_liquid_syntax_error?(cleaned_message)

      if (match = cleaned_message.match(/\AMust include the required variable (.+) in the subject or body\z/))
        return "Add the required variable #{match[1]} using Insert Variable."
      end

      cleaned_message
    end

    # Provides sample data for rendering email template previews or tests.
    # Auto-extracts variables from the template body and generates generic sample values.
    def sample_data_for_template(template_name, locale: 'en', subject: nil, format: :text,
                                 include_optional_variables: nil)
      template = EmailTemplate.find_by(name: template_name, format: format, locale: locale) ||
                 EmailTemplate.find_by(name: template_name, format: format, locale: I18n.default_locale.to_s)
      return base_sample_data(locale: locale, subject: subject) unless template

      sample_data_for_email_template(template,
                                     locale: locale,
                                     subject: subject || template.subject,
                                     include_optional_variables: include_optional_variables)
    end

    def sample_data_for_email_template(template, locale: template.locale, subject: nil, include_optional_variables: nil)
      include_optional_variables = !template.liquid? if include_optional_variables.nil?
      base = base_sample_data(locale: locale, subject: subject || template.subject)
      base = remove_sample_paths(base, optional_only_variables(template)) unless include_optional_variables
      generated = generated_sample_data_for(template, base, include_optional_variables: include_optional_variables)
      base.deep_merge(generated)
    end

    private

    def display_template_body_line(line)
      placeholder_name = layout_placeholder_line_name(line)
      return line unless placeholder_name

      "[Layout placeholder: #{placeholder_for_line(line)}]\n"
    end

    def layout_placeholder_line_name(line)
      stripped = line.to_s.strip
      legacy_placeholder_name(stripped) || liquid_placeholder_name(stripped)
    end

    def legacy_placeholder_name(stripped)
      name = stripped.match(/\A%[<{]([a-zA-Z_]\w*)[>}]s?\z/)&.captures&.first
      LAYOUT_PLACEHOLDER_NAMES.include?(name) ? name : nil
    end

    def liquid_placeholder_name(stripped)
      name = stripped.match(/\A\{\{-?\s*([a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*)\s*-?\}\}\z/)&.captures&.first
      LAYOUT_PLACEHOLDER_NAMES.include?(name) ? name : nil
    end

    def placeholder_for_line(line)
      line.to_s.strip
    end

    def admin_actionable_template_error?(message)
      message.include?('Use variables from Insert Variable only') ||
        message.include?('Liquid templates can only use Required Variables') ||
        message.include?('still has standard placeholders') ||
        message.include?('not enabled yet') ||
        message.include?('only available for text templates')
    end

    def template_placeholder_error?(message)
      message.match?(/Liquid|placeholder|syntax|variable|required|render/i)
    end

    def invalid_liquid_syntax_error?(message)
      message.match?(/Invalid Liquid syntax|Liquid syntax error/i)
    end

    def optional_only_variables(template)
      template.optional_variables.map(&:to_s) - template.required_variables.map(&:to_s)
    end

    def remove_sample_paths(sample_data, variable_paths)
      sample_data = sample_data.deep_dup
      variable_paths.each { |variable_path| delete_sample_path(sample_data, variable_path) }
      sample_data
    end

    def delete_sample_path(sample_data, variable_path)
      sample_data.delete(variable_path)
      sample_data.delete(variable_path.to_sym)

      segments = variable_path.to_s.split('.')
      final_segment = segments.pop
      cursor = sample_data

      segments.each do |segment|
        cursor = cursor[segment] || cursor[segment.to_sym]
        cursor = nil unless cursor.is_a?(Hash)
        break unless cursor
      end
      return unless cursor

      cursor.delete(final_segment)
      cursor.delete(final_segment.to_sym)
    end

    def generated_sample_data_for(template, base, include_optional_variables:)
      omitted_paths = include_optional_variables ? [] : optional_only_variables(template)

      template.extract_variables.each_with_object({}) do |variable_path, generated|
        next if omitted_paths.include?(variable_path)
        next if sample_data_path_available?(base, variable_path)

        assign_sample_path(generated, variable_path, "Sample #{variable_path.tr('.', ' ').humanize.titleize}")
      end
    end

    def sample_data_path_available?(sample_data, variable_path)
      return true if sample_data.key?(variable_path)
      return true if sample_data.key?(variable_path.to_sym)

      cursor = sample_data
      variable_path.to_s.split('.').all? do |segment|
        case cursor
        when Hash
          if cursor.key?(segment)
            cursor = cursor[segment]
          elsif cursor.key?(segment.to_sym)
            cursor = cursor[segment.to_sym]
          else
            false
          end
        else
          false
        end
      end
    end

    def assign_sample_path(sample_data, variable_path, value)
      segments = variable_path.to_s.split('.')
      final_segment = segments.pop
      cursor = sample_data

      segments.each do |segment|
        cursor[segment] ||= {}
        cursor = cursor[segment]
      end

      cursor[final_segment] = value
    end

    # Base sample data shared across all templates
    def base_sample_data(locale: 'en', subject: nil) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      is_es = locale.to_s == 'es'
      {
        'header_text' => render(partial: 'shared/mailers/header', formats: [:text],
                                locals: { title: subject || (is_es ? 'Título de Correo de Muestra' : 'Sample Email Title') }),
        'footer_text' => render(partial: 'shared/mailers/footer', formats: [:text], locals: { show_automated_message: true }),
        'header_logo_url' => asset_url('TAM_color.png'),
        'header_subtitle' => is_es ? 'Subtítulo de Muestra' : 'Sample Subtitle',
        'footer_contact_email' => 'support@example.com',
        'footer_website_url' => ProgramContact.website_url,
        'footer_show_automated_message' => true,
        'organization_name' => 'Maryland Accessible Telecommunications',
        'office_address' => ProgramContact.office_address,
        'program_website_url' => ProgramContact.website_url,
        'sign_in_url' => 'http://example.com/sign_in',
        'dashboard_url' => 'http://example.com/dashboard',
        'admin_dashboard_url' => 'http://example.com/admin/dashboard',
        'vendor_portal_url' => 'http://example.com/vendor',
        'application_id' => '12345',
        'user_first_name' => is_es ? 'Alejandro' : 'Alex',
        'user_email' => 'alex@example.com',
        'constituent_first_name' => is_es ? 'Jaime' : 'Jamie',
        'constituent_full_name' => is_es ? 'Jaime Doe' : 'Jamie Doe',
        'constituent_dob_formatted' => is_es ? '15 de Enero, 1985' : 'January 15, 1985',
        'constituent_address_formatted' => "123 Main St\nAnytown, MD 12345",
        'constituent_phone_formatted' => '555-123-4567',
        'constituent_email' => 'jamie.doe@example.com',
        'admin_full_name' => 'Admin User',
        'admin_first_name' => 'Admin User',
        'evaluator_full_name' => 'Dr. Evaluation Expert',
        'trainer_full_name' => 'Training Specialist',
        'vendor_business_name' => 'Example Vendor Inc.',
        'timestamp_formatted' => Time.current.strftime('%B %d, %Y at %I:%M %p %Z'),
        'submission_date_formatted' => Date.current.strftime('%B %d, %Y'),
        'expiration_date_formatted' => (Date.current + 3.months).strftime('%B %d, %Y'),
        'reapply_date_formatted' => (Date.current + 6.months).strftime('%B %d, %Y'),
        'transaction_date_formatted' => Date.current.strftime('%B %d, %Y'),
        'period_start_formatted' => (Date.current - 1.month).beginning_of_month.strftime('%B %d, %Y'),
        'period_end_formatted' => (Date.current - 1.month).end_of_month.strftime('%B %d, %Y'),
        'status_box_text' => is_es ? 'INFO: Mensaje de estado de muestra' : 'INFO: Sample Status Message',
        'status_box_warning_text' => is_es ? 'ADVERTENCIA: Mensaje de advertencia de muestra' : 'WARNING: Sample Warning Message',
        'status_box_info_text' => is_es ? 'INFO: Mensaje de información de muestra' : 'INFO: Sample Info Message',
        'error_message' => is_es ? 'Ocurrió un error de muestra durante el procesamiento.' : 'A sample error occurred during processing.',
        'rejection_reason' => is_es ? 'La información proporcionada estaba incompleta.' : 'Information provided was incomplete.',
        'additional_instructions' => is_es ? 'Por favor, proporcione los documentos X, Y y Z.' : 'Please provide documents X, Y, and Z.',
        'remaining_attempts' => 2,
        'active_vendors_text_list' => "- Vendor A\n- Vendor B",
        'stale_reviews_count' => 5,
        'stale_reviews_text_list' => "- App 1\n- App 2\n- App 3\n- App 4\n- App 5",
        'constituent_disabilities_text_list' => "- Disability 1\n- Disability 2",
        'evaluators_evaluation_url' => 'http://example.com/evaluators/evaluations/1',
        'verification_url' => 'http://example.com/identity/email_verifications/TOKEN',
        'reset_url' => 'http://example.com/identity/password_resets/TOKEN',
        'invoice_number' => 'INV-2025-001',
        'total_amount_formatted' => '$1,234.56',
        'transactions_text_list' => "- Txn 1: $100\n- Txn 2: $200",
        'gad_invoice_reference' => 'GADREF98765',
        'check_number' => 'CHK1001',
        'days_until_expiry' => 30,
        'vendor_association_message' => is_es ? 'Tu asociación está activa.' : 'Your association is active.',
        'voucher_code' => 'VOUCHER123XYZ',
        'initial_value_formatted' => '$500.00',
        'unused_value_formatted' => '$150.00',
        'remaining_balance_formatted' => '$350.00',
        'validity_period_months' => 6,
        'minimum_redemption_amount_formatted' => '$25.00',
        'transaction_amount_formatted' => '$150.00',
        'transaction_reference_number' => 'TXNREFABCDE',
        'transaction_history_text' => is_es ? "- Canjeó $100 en el Vendedor A\n- Canjeó $50 en el Vendedor B" : "- Redeemed $100 at Vendor A\n- Redeemed $50 at Vendor B",
        'remaining_value_message_text' => is_es ? 'Tu saldo restante es de $350.00.' : 'Your remaining balance is $350.00.',
        'fully_redeemed_message_text' => is_es ? 'Este vale ha sido canjeado en su totalidad.' : 'This voucher has been fully redeemed.',
        'download_form_url' => 'http://example.com/forms/medical_cert.pdf',
        'request_count_message' => is_es ? '(Solicitud #1)' : '(Request #1)',
        'temp_password' => 'temporaryP@ssw0rd',
        'household_size' => 4,
        'annual_income_formatted' => '$45,000.00',
        'threshold_formatted' => '$55,000.00',
        'proof_type_formatted' => is_es ? 'Verificación de Ingresos' : 'Income Verification',
        'additional_notes' => is_es ? 'Estas son algunas notas adicionales.' : 'These are some additional notes.'
      }
    end
  end
end
