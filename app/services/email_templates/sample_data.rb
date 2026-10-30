# frozen_string_literal: true

module EmailTemplates
  # Sample values for previewing, testing and validating an email template: realistic placeholders for the
  # variables the program's emails share, plus a generated value for any variable the template adds.
  class SampleData
    def self.for_template_name(template_name, locale: 'en', subject: nil, format: :text, include_optional_variables: nil)
      template = EmailTemplate.find_with_locale(name: template_name, format: format, locale: locale)
      return new(locale: locale).base(subject: subject) unless template

      for_template(template, locale: locale, subject: subject || template.subject, include_optional_variables: include_optional_variables)
    end

    def self.for_template(template, locale: template.locale, subject: nil, include_optional_variables: nil)
      new(locale: locale).for_template(template, subject: subject, include_optional_variables: include_optional_variables)
    end

    def initialize(locale:)
      @locale = locale
    end

    def for_template(template, subject: nil, include_optional_variables: nil)
      include_optional_variables = !template.liquid? if include_optional_variables.nil?
      base_data = base(subject: subject || template.subject)
      base_data = remove_sample_paths(base_data, optional_only_variables(template)) unless include_optional_variables
      generated = generated_sample_data_for(template, base_data, include_optional_variables: include_optional_variables)
      base_data.deep_merge(generated)
    end

    def base(subject: nil) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      locale = @locale
      is_es = locale.to_s == 'es'
      {
        'header_text' => ApplicationController.render(partial: 'shared/mailers/header', formats: [:text],
                                                      locals: { title: subject || (is_es ? 'Título de Correo de Muestra' : 'Sample Email Title') }),
        'footer_text' => ApplicationController.render(partial: 'shared/mailers/footer', formats: [:text], locals: { show_automated_message: true }),
        'header_logo_url' => ActionController::Base.helpers.asset_url('TAM_color.png'),
        'header_subtitle' => is_es ? 'Subtítulo de Muestra' : 'Sample Subtitle',
        'footer_contact_email' => ProgramContact.support_email,
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
        'trainer_full_name' => is_es ? 'Especialista de capacitación' : 'Training Specialist',
        'vendor_business_name' => 'Example Vendor Inc.',
        'timestamp_formatted' => Time.current.strftime('%B %d, %Y at %I:%M %p %Z'),
        'submission_date_formatted' => Date.current.strftime('%B %d, %Y'),
        'expiration_date_formatted' => (Date.current + 3.months).strftime('%B %d, %Y'),
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
        'verification_url' => 'http://example.com/verify_email?token=TOKEN',
        'reset_url' => 'http://example.com/password/edit?locale=en&token=TOKEN',
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
        'download_form_url' => 'http://example.com/forms/disability_cert.pdf',
        'request_count_message' => is_es ? '(Solicitud #1)' : '(Request #1)',
        'temp_password' => 'temporaryP@ssw0rd',
        'household_size' => 4,
        'annual_income_formatted' => '$45,000.00',
        'threshold_formatted' => '$55,000.00',
        'proof_type_formatted' => is_es ? 'Verificación de Ingresos' : 'Income Verification',
        'additional_notes' => is_es ? 'Estas son algunas notas adicionales.' : 'These are some additional notes.'
      }.merge(training_completion_sample_data)
    end

    private

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

    def training_completion_sample_data
      locale = @locale
      is_es = locale.to_s == 'es'
      {
        'recipient_full_name' => is_es ? 'María García' : 'Jamie Doe',
        'completed_date_formatted' => I18n.l(1.day.ago.to_date, format: :long, locale: locale),
        'completed_time_formatted' => 1.day.ago.strftime('%H:%M %Z'),
        'report_access_text' => I18n.t('training_session_notifications.training_completed.report_accessible', locale: locale),
        'report_url' => 'https://example.com/constituent_portal/training_sessions/123',
        'scheduled_location' => is_es ? 'Biblioteca, sala 2' : 'Library, room 2'
      }
    end
  end
end
