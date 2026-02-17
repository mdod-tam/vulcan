class FillEmailTemplatesVariables < ActiveRecord::Migration[8.0]
  TEMPLATE_CONFIG = {
    'application_notifications_application_submitted' => {
      required: %w[user_first_name application_id submission_date_formatted header_text footer_text],
      optional: []
    },
    'application_notifications_account_created' => {
      required: %w[constituent_first_name constituent_email temp_password sign_in_url header_text footer_text],
      optional: []
    },
    'application_notifications_income_threshold_exceeded' => {
      required: %w[constituent_first_name household_size annual_income_formatted threshold_formatted header_text footer_text],
      optional: %w[additional_notes]
    },
    'application_notifications_max_rejections_reached' => {
      required: %w[user_first_name application_id reapply_date_formatted header_text footer_text],
      optional: []
    },
    'application_notifications_proof_approved' => {
      required: %w[user_first_name organization_name proof_type_formatted header_text footer_text],
      optional: %w[all_proofs_approved_message_text ]
    },
    'application_notifications_proof_received' => {
      required: %w[user_first_name organization_name proof_type_formatted header_text footer_text],
      optional: []
    },
    'application_notifications_proof_needs_review_reminder' => {
      required: %w[admin_full_name stale_reviews_count stale_reviews_text_list admin_dashboard_url header_text footer_text],
      optional: []
    },
    'application_notifications_proof_rejected' => {
      required: %w[constituent_full_name organization_name proof_type_formatted rejection_reason header_text footer_text],
      optional: %w[remaining_attempts_message_text]
    },
    'application_notifications_proof_submission_error' => {
      required: %w[constituent_full_name message header_text footer_text],
      optional: []
    },
    'application_notifications_registration_confirmation' => {
      required: %w[user_full_name dashboard_url new_application_url header_text footer_text active_vendors_text_list],
      optional: []
    },
    'medical_provider_certification_rejected' => {
      required: %w[constituent_full_name application_id rejection_reason remaining_attempts],
      optional: []
    },
    'medical_provider_request_certification' => {
      required: %w[constituent_full_name request_count_message timestamp_formatted constituent_dob_formatted constituent_address_formatted application_id download_form_url],
      optional: []
    },
    'medical_provider_certification_submission_error' => {
      required: %w[medical_provider_email error_message],
      optional: []
    },
    'medical_provider_notifications_certification_processing_error' => {
      required: %w[constituent_full_name application_id error_message],
      optional: []
    },
    'medical_provider_notifications_certification_revision_needed' => {
      required: %w[constituent_full_name application_id rejection_reason remaining_attempts],
      optional: []
    },
    'evaluator_mailer_evaluation_submission_confirmation' => {
      required: %w[constituent_first_name application_id evaluator_full_name submission_date_formatted header_text footer_text status_box_text],
      optional: []
    },
    'evaluator_mailer_new_evaluation_assigned' => {
      required: %w[evaluator_full_name constituent_full_name constituent_address_formatted constituent_phone_formatted constituent_email evaluators_evaluation_url header_text footer_text status_box_text constituent_disabilities_text_list],
      optional: []
    },
    'user_mailer_email_verification' => {
      required: %w[user_email verification_url],
      optional: []
    },
    'user_mailer_password_reset' => {
      required: %w[user_email reset_url],
      optional: []
    },
    'vendor_notifications_invoice_generated' => {
      required: %w[vendor_business_name invoice_number period_start_formatted period_end_formatted total_amount_formatted transactions_text_list],
      optional: []
    },
    'vendor_notifications_payment_issued' => {
      required: %w[vendor_business_name invoice_number total_amount_formatted gad_invoice_reference],
      optional: %w[check_number]
    },
    'vendor_notifications_w9_approved' => {
      required: %w[vendor_business_name status_box_text header_text footer_text],
      optional: []
    },
    'vendor_notifications_w9_rejected' => {
      required: %w[vendor_business_name rejection_reason vendor_portal_url status_box_text header_text footer_text],
      optional: []
    },
    'vendor_notifications_w9_expiring_soon' => {
      required: %w[vendor_business_name days_until_expiry expiration_date_formatted vendor_portal_url status_box_warning_text status_box_info_text header_text footer_text],
      optional: []
    },
    'vendor_notifications_w9_expired' => {
      required: %w[vendor_business_name expiration_date_formatted vendor_portal_url status_box_warning_text status_box_info_text status_box_error_text header_text footer_text],
      optional: []
    },
    'voucher_notifications_voucher_assigned' => {
      required: %w[user_first_name voucher_code initial_value_formatted expiration_date_formatted validity_period_months minimum_redemption_amount_formatted],
      optional: []
    },
    'voucher_notifications_voucher_expired' => {
      required: %w[user_first_name voucher_code initial_value_formatted unused_value_formatted expiration_date_formatted header_text footer_text],
      optional: %w[transaction_history_text]
    },
    'voucher_notifications_voucher_redeemed' => {
      required: %w[user_first_name transaction_date_formatted transaction_amount_formatted vendor_business_name transaction_reference_number voucher_code remaining_balance_formatted expiration_date_formatted remaining_value_message_text fully_redeemed_message_text redeemed_value_formatted],
      optional: []
    },
    'voucher_notifications_voucher_expiring_soon' => {
      required: %w[vendor_business_name days_until_expiry expiration_date_formatted status_box_warning_text status_box_info_text voucher_code remaining_value_formatted minimum_redemption_amount_formatted],
      optional: []
    },
    'training_session_notifications_trainer_assigned' => {
      required: %w[trainer_full_name trainer_email trainer_phone_formatted constituent_full_name constituent_address_formatted constituent_phone_formatted constituent_email training_session_schedule_text header_text footer_text constituent_disabilities_text_list status_box_text],
      optional: []
    },
    'training_session_notifications_training_scheduled' => {
      required: %w[constituent_full_name trainer_full_name trainer_email trainer_phone_formatted scheduled_date_formatted scheduled_time_formatted trainer_email trainer_phone_formatted header_text footer_text],
      optional: []
    },
    'training_session_notifications_training_completed' => {
      required: %w[constituent_full_name trainer_full_name trainer_email trainer_phone_formatted completed_date_formatted application_id trainer_email trainer_phone_formatted header_text footer_text],
      optional: []
    },
    'training_session_notifications_training_cancelled' => {
      required: %w[constituent_full_name scheduled_date_time_formatted support_email header_text footer_text],
      optional: []
    },
    'training_session_notifications_training_no_show' => {
      required: %w[constituent_full_name trainer_email scheduled_date_time_formatted support_email header_text footer_text],
      optional: []
    },
    'email_footer_text' => {
      required: %w[organization_name contact_email website_url],
      optional: %w[show_automated_message]
    },
    'email_header_text' =>{
      required: %w[title],
      optional: %w[subtitle]
    }
  }

  def up
    TEMPLATE_CONFIG.each do |name, config|
      templates = EmailTemplate.where(name: name)

      templates.each do |template|
        new_variables = {
          'required' => config[:required],
          'optional' => config[:optional]
        }
        template.update_columns(variables: new_variables)

        puts "Updated variables for: #{name}"
      end
    end
  end

  def down 
    EmailTemplate.update_all(variables: { 'required' => [], 'optional' => []})
  end
  
end
