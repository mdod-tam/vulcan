# frozen_string_literal: true

module Admin
  module EmailTemplatesHelper
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
      template&.needs_sync? ? 'Needs sync' : 'In sync'
    end

    def template_sync_badge_classes(template)
      if template&.needs_sync?
        'inline-flex items-center rounded-full bg-amber-100 px-3 py-1 text-xs font-medium text-amber-800'
      else
        'inline-flex items-center rounded-full bg-emerald-100 px-3 py-1 text-xs font-medium text-emerald-800'
      end
    end

    # Provides sample data for rendering email template previews or tests.
    # Auto-extracts variables from the template body and generates generic sample values.
    def sample_data_for_template(template_name)
      template = EmailTemplate.find_by(name: template_name)
      return base_sample_data unless template

      # Auto-generate sample data for extracted variables
      generated = template.extract_variables.each_with_object({}) do |var, hash|
        hash[var] = "Sample #{var.humanize}"
      end

      base_sample_data.merge(generated)
    end

    private

    # Base sample data shared across all templates
    def base_sample_data
      {
        'header_text' => render(partial: 'shared/mailers/header', formats: [:text], locals: { title: 'Sample Email Title' }),
        'footer_text' => render(partial: 'shared/mailers/footer', formats: [:text], locals: { show_automated_message: true }),
        'header_logo_url' => asset_url('TAM_color.png'),
        'header_subtitle' => 'Sample Subtitle',
        'footer_contact_email' => 'support@example.com',
        'footer_website_url' => 'http://example.com',
        'footer_show_automated_message' => true,
        'organization_name' => 'Maryland Accessible Telecommunications',
        'sign_in_url' => 'http://example.com/sign_in',
        'dashboard_url' => 'http://example.com/dashboard',
        'admin_dashboard_url' => 'http://example.com/admin/dashboard',
        'vendor_portal_url' => 'http://example.com/vendor',
        'application_id' => '12345',
        'user_first_name' => 'Alex',
        'user_email' => 'alex@example.com',
        'constituent_first_name' => 'Jamie',
        'constituent_full_name' => 'Jamie Doe',
        'constituent_dob_formatted' => 'January 15, 1985',
        'constituent_address_formatted' => "123 Main St\nAnytown, MD 12345",
        'constituent_phone_formatted' => '555-123-4567',
        'constituent_email' => 'jamie.doe@example.com',
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
        'status_box_text' => 'INFO: Sample Status Message',
        'status_box_warning_text' => 'WARNING: Sample Warning Message',
        'status_box_info_text' => 'INFO: Sample Info Message',
        'error_message' => 'A sample error occurred during processing.',
        'rejection_reason' => 'Information provided was incomplete.',
        'additional_instructions' => 'Please provide documents X, Y, and Z.',
        'remaining_attempts' => 2,
        'remaining_attempts_message_text' => 'You have 2 attempts remaining.',
        'archived_message_text' => 'Your application has been archived.',
        'default_options_text' => 'Please sign in to review.',
        'all_proofs_approved_message_text' => 'All required proofs have been approved!',
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
        'vendor_association_message' => 'Your association is active.',
        'voucher_code' => 'VOUCHER123XYZ',
        'initial_value_formatted' => '$500.00',
        'unused_value_formatted' => '$150.00',
        'remaining_balance_formatted' => '$350.00',
        'validity_period_months' => 6,
        'minimum_redemption_amount_formatted' => '$25.00',
        'transaction_amount_formatted' => '$150.00',
        'transaction_reference_number' => 'TXNREFABCDE',
        'transaction_history_text' => "- Redeemed $100 at Vendor A\n- Redeemed $50 at Vendor B",
        'remaining_value_message_text' => 'Your remaining balance is $350.00.',
        'fully_redeemed_message_text' => 'This voucher has been fully redeemed.',
        'download_form_url' => 'http://example.com/forms/medical_cert.pdf',
        'request_count_message' => '(Request #1)',
        'temp_password' => 'temporaryP@ssw0rd',
        'household_size' => 4,
        'annual_income_formatted' => '$45,000.00',
        'threshold_formatted' => '$55,000.00',
        'proof_type_formatted' => 'Income Verification',
        'additional_notes' => 'These are some additional notes.'
      }
    end
  end
end
