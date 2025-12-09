# frozen_string_literal: true

module Admin
  module EmailTemplatesHelper
    # Provides sample data for rendering email template previews or tests.
    # Returns a hash with string keys matching the %{variable_name} placeholders.
    def sample_data_for_template(template_name)
      base_sample_data.merge(template_specific_data(template_name))
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
        'user_full_name' => 'Alex Johnson',
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
        'stale_reviews_text_list' => "- App 1\n- App 2\n- App 3\n- App 4\n- App 5", # Placeholder
        'constituent_disabilities_text_list' => "- Disability 1\n- Disability 2", # Placeholder
        'evaluators_evaluation_url' => 'http://example.com/evaluators/evaluations/1',
        'verification_url' => 'http://example.com/identity/email_verifications/TOKEN',
        'reset_url' => 'http://example.com/identity/password_resets/TOKEN',
        'invoice_number' => 'INV-2025-001',
        'total_amount_formatted' => '$1,234.56',
        'transactions_text_list' => "- Txn 1: $100\n- Txn 2: $200", # Placeholder
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
        'transaction_history_text' => "- Redeemed $100 at Vendor A\n- Redeemed $50 at Vendor B", # Placeholder
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

    # Template-specific data overrides
    def template_specific_data(template_name)
      case template_name.to_sym
      when :vendor_notifications_invoice_generated
        vendor_invoice_data
      when :vendor_notifications_payment_issued
        vendor_payment_data
      when :vendor_notifications_w9_approved, :vendor_notifications_w9_rejected,
            :vendor_notifications_w9_expired, :vendor_notifications_w9_expiring_soon
        vendor_w9_data(template_name)
      when :email_header_text
        email_header_data
      when :email_footer_text
        email_footer_data
      when :application_notifications_account_created
        application_account_created_data
      when :application_notifications_income_threshold_exceeded
        income_threshold_data
      when :application_notifications_registration_confirmation
        registration_confirmation_data
      when :application_notifications_proof_submission_error
        proof_submission_error_data
      when :medical_provider_certification_submission_error
        certification_submission_error_data
      when :training_session_notifications_training_scheduled
        training_scheduled_data
      when :training_session_notifications_training_cancelled
        training_cancelled_data
      when :training_session_notifications_training_completed
        training_completed_data
      when :training_session_notifications_training_no_show
        training_no_show_data
      when :voucher_notifications_voucher_redeemed
        voucher_redeemed_data
      when :admin_notifications_stale_reviews_summary
        stale_reviews_data
      else
        {} # Return empty hash for no overrides
      end
    end

    def vendor_invoice_data
      {
        'header_title' => 'Vendor Notification: Invoice Generated',
        'vendor_business_name' => 'Baltimore Accessible Tech Solutions',
        'vendor_contact_name' => 'Morgan Johnson',
        'vendor_contact_email' => 'morgan@baltimoreats.com',
        'invoice_number' => 'INV-2025-042',
        'period_start_formatted' => (Date.current - 1.month).beginning_of_month.strftime('%B %d, %Y'),
        'period_end_formatted' => (Date.current - 1.month).end_of_month.strftime('%B %d, %Y'),
        'total_amount_formatted' => '$1,875.50',
        'transactions_text_list' => "- Voucher #V0012345: $550.00\n- Voucher #V0012346: $725.50\n- Voucher #V0012347: $600.00"
      }
    end

    def vendor_payment_data
      {
        'header_title' => 'Vendor Notification: Payment Issued',
        'vendor_business_name' => 'Baltimore Accessible Tech Solutions',
        'vendor_contact_name' => 'Morgan Johnson',
        'vendor_contact_email' => 'morgan@baltimoreats.com',
        'invoice_number' => 'INV-2025-042',
        'total_amount_formatted' => '$1,875.50'
      }
    end

    def vendor_w9_data(template_name)
      {
        'header_title' => "Vendor Notification: W9 #{template_name.to_s.split('_').last.capitalize}",
        'vendor_business_name' => 'Baltimore Accessible Tech Solutions',
        'vendor_contact_name' => 'Morgan Johnson',
        'vendor_contact_email' => 'morgan@baltimoreats.com',
        'days_until_expiry' => 30
      }
    end

    def email_header_data
      {
        'title' => 'Sample Email Title',
        'subtitle' => 'Sample Subtitle'
      }
    end

    def email_footer_data
      {
        'contact_email' => 'support@example.com',
        'footer_website_url' => 'http://example.com',
        'show_automated_message' => true
      }
    end

    def application_account_created_data
      {
        'title' => 'Account Created',
        'constituent_first_name' => 'Jamie',
        'constituent_email' => 'jamie.doe@example.com',
        'sign_in_url' => 'http://example.com/sign_in',
        'temp_password' => 'temporaryP@ssw0rd'
      }
    end

    def income_threshold_data
      {
        'header_title' => 'Income Threshold Exceeded',
        'constituent_first_name' => 'Jamie',
        'annual_income_formatted' => '$65,000.00',
        'threshold_formatted' => '$55,000.00'
      }
    end

    def registration_confirmation_data
      {
        'header_title' => 'Registration Confirmation',
        'new_application_url' => 'http://example.com/applications/12'
      }
    end

    def proof_submission_error_data
      {
        'header_title' => 'Proof Submission Error',
        'constituent_first_name' => 'Jamie',
        'proof_type_formatted' => 'Income Verification',
        'message' => 'The document could not be processed. Please try again.',
        'additional_instructions' => 'Please ensure the document is clear and readable.'
      }
    end

    def certification_submission_error_data
      {
        'header_title' => 'Medical Certification Submission Error',
        'error_message' => 'The medical certification could not be processed.',
        'medical_provider_email' => 'medical.provider@example.com'
      }
    end

    def training_scheduled_data
      {
        'header_title' => 'Training Scheduled',
        'constituent_first_name' => 'Jamie',
        'trainer_full_name' => 'Training Specialist',
        'submission_date_formatted' => Date.current.strftime('%B %d, %Y'),
        'request_count_message' => '(Request #1)'
      }
    end

    def training_cancelled_data
      {
        'header_title' => 'Training Cancelled',
        'constituent_first_name' => 'Jamie',
        'trainer_full_name' => 'Training Specialist',
        'rejection_reason' => 'Training session was cancelled due to scheduling conflict.',
        'support_email' => 'trainingsupport@example.com',
        'scheduled_date_time_formatted' => Date.current.strftime('%B %d, %Y at %I:%M %p %Z')
      }
    end

    def training_completed_data
      {
        'header_title' => 'Training Completed',
        'constituent_first_name' => 'Jamie',
        'completed_date_formatted' => Date.current.strftime('%B %d, %Y'),
        'trainer_full_name' => 'Training Specialist',
        'trainer_email' => 'trainingsupport@example.com',
        'trainer_phone_formatted' => '555-123-4567',
        'submission_date_formatted' => Date.current.strftime('%B %d, %Y')
      }
    end

    def training_no_show_data
      {
        'header_title' => 'Training Session Missed',
        'constituent_first_name' => 'Jamie',
        'trainer_full_name' => 'Training Specialist',
        'submission_date_formatted' => Date.current.strftime('%B %d, %Y'),
        'remaining_attempts_message_text' => 'You have 2 attempts remaining.'
      }
    end

    def voucher_redeemed_data
      {
        'header_title' => 'Voucher Redeemed',
        'constituent_first_name' => 'Jamie',
        'voucher_code' => 'VOUCHER123XYZ',
        'transaction_amount_formatted' => '$150.00',
        'remaining_balance_formatted' => '$350.00'
      }
    end

    def stale_reviews_data
      {
        'header_title' => 'Stale Reviews Summary',
        'admin_full_name' => 'Sally Smythe',
        'stale_reviews_count' => 5,
        'stale_reviews_text_list' => "- Application #1001\n- Application #1002\n- Application #1003\n- Application #1004\n- Application #1005"
      }
    end
  end
end
