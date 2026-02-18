# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_02_17_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accessories_evaluations", id: false, force: :cascade do |t|
    t.bigint "evaluation_id", null: false
    t.bigint "accessory_id", null: false
  end

  create_table "action_mailbox_inbound_emails", force: :cascade do |t|
    t.integer "status", default: 0, null: false
    t.string "message_id", null: false
    t.string "message_checksum", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id", "message_checksum"], name: "index_action_mailbox_inbound_emails_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "application_notes", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.bigint "admin_id", null: false
    t.text "content", null: false
    t.boolean "internal_only", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["admin_id"], name: "index_application_notes_on_admin_id"
    t.index ["application_id"], name: "index_application_notes_on_application_id"
  end

  create_table "application_status_changes", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.bigint "user_id"
    t.string "from_status", null: false
    t.string "to_status", null: false
    t.datetime "changed_at", null: false
    t.text "notes"
    t.json "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "change_type"
    t.index ["application_id"], name: "index_application_status_changes_on_application_id"
    t.index ["changed_at"], name: "index_application_status_changes_on_changed_at"
    t.index ["user_id"], name: "index_application_status_changes_on_user_id"
  end

  create_table "applications", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "status"
    t.integer "application_type"
    t.integer "submission_method"
    t.datetime "application_date"
    t.integer "household_size"
    t.decimal "annual_income"
    t.datetime "income_verified_at"
    t.bigint "income_verified_by_id"
    t.text "income_details"
    t.text "residency_details"
    t.string "current_step"
    t.datetime "received_at"
    t.datetime "last_activity_at"
    t.integer "review_count"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "self_certify_disability"
    t.boolean "maryland_resident"
    t.boolean "terms_accepted"
    t.boolean "information_verified"
    t.boolean "medical_release_authorized"
    t.string "medical_provider_name"
    t.string "medical_provider_phone"
    t.string "medical_provider_fax"
    t.string "medical_provider_email"
    t.integer "total_rejections", default: 0, null: false
    t.datetime "last_proof_submitted_at"
    t.datetime "needs_review_since"
    t.integer "medical_certification_status", default: 0, null: false
    t.datetime "medical_certification_verified_at"
    t.bigint "medical_certification_verified_by_id"
    t.text "medical_certification_rejection_reason"
    t.datetime "medical_certification_requested_at"
    t.integer "medical_certification_request_count", default: 0
    t.string "last_visited_step"
    t.bigint "managing_guardian_id"
    t.string "alternate_contact_name"
    t.string "alternate_contact_phone"
    t.string "alternate_contact_email"
    t.integer "income_proof_status", default: 0, null: false
    t.integer "residency_proof_status", default: 0, null: false
    t.integer "document_signing_status", default: 0, null: false
    t.string "document_signing_service"
    t.string "document_signing_submission_id"
    t.string "document_signing_submitter_id"
    t.datetime "document_signing_requested_at"
    t.datetime "document_signing_signed_at"
    t.integer "document_signing_request_count", default: 0, null: false
    t.text "document_signing_audit_url"
    t.text "document_signing_document_url"
    t.index ["document_signing_service"], name: "index_applications_on_document_signing_service"
    t.index ["document_signing_status"], name: "index_applications_on_document_signing_status"
    t.index ["document_signing_submission_id"], name: "index_applications_on_document_signing_submission_id"
    t.index ["income_proof_status"], name: "idx_applications_on_income_proof_status"
    t.index ["income_verified_by_id"], name: "index_applications_on_income_verified_by_id"
    t.index ["last_proof_submitted_at"], name: "index_applications_on_last_proof_submitted_at"
    t.index ["managing_guardian_id"], name: "index_applications_on_managing_guardian_id"
    t.index ["medical_certification_status"], name: "index_applications_on_medical_certification_status"
    t.index ["medical_certification_verified_by_id"], name: "index_applications_on_medical_certification_verified_by_id"
    t.index ["medical_provider_email", "status"], name: "index_applications_on_medical_provider_email_and_status"
    t.index ["needs_review_since"], name: "index_applications_on_needs_review_since"
    t.index ["residency_proof_status"], name: "idx_applications_on_residency_proof_status"
    t.index ["status", "needs_review_since"], name: "index_applications_on_status_and_needs_review_since"
    t.index ["total_rejections"], name: "index_applications_on_total_rejections"
    t.index ["user_id"], name: "index_applications_on_user_id"
    t.check_constraint "income_proof_status = ANY (ARRAY[0, 1, 2])", name: "income_proof_status_check"
    t.check_constraint "residency_proof_status = ANY (ARRAY[0, 1, 2])", name: "residency_proof_status_check"
  end

  create_table "applications_products", id: false, force: :cascade do |t|
    t.bigint "application_id", null: false
    t.bigint "product_id", null: false
    t.index ["application_id", "product_id"], name: "index_applications_products_on_application_id_and_product_id"
    t.index ["product_id", "application_id"], name: "index_applications_products_on_product_id_and_application_id"
  end

  create_table "email_templates", force: :cascade do |t|
    t.string "name", null: false
    t.string "subject"
    t.text "body"
    t.jsonb "variables", default: {}
    t.bigint "updated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "format", default: 0
    t.text "description"
    t.integer "version", default: 1
    t.string "previous_subject"
    t.text "previous_body"
    t.boolean "enabled", default: true, null: false
    t.string "locale", default: "en", null: false
    t.boolean "needs_sync", default: false, null: false
    t.index ["enabled"], name: "index_email_templates_on_enabled"
    t.index ["name", "format", "locale"], name: "index_email_templates_on_name_format_locale", unique: true
    t.index ["updated_by_id"], name: "index_email_templates_on_updated_by_id"
  end

  create_table "evaluations", force: :cascade do |t|
    t.bigint "evaluator_id", null: false
    t.bigint "constituent_id", null: false
    t.datetime "evaluation_date"
    t.integer "evaluation_type"
    t.boolean "report_submitted"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "status", default: 0
    t.bigint "application_id", null: false
    t.text "needs"
    t.string "location"
    t.jsonb "attendees", default: []
    t.jsonb "products_tried", default: []
    t.text "reschedule_reason"
    t.index ["application_id"], name: "index_evaluations_on_application_id"
    t.index ["constituent_id"], name: "index_evaluations_on_constituent_id"
    t.index ["evaluator_id"], name: "index_evaluations_on_evaluator_id"
  end

  create_table "evaluations_products", id: false, force: :cascade do |t|
    t.bigint "evaluation_id", null: false
    t.bigint "product_id", null: false
    t.index ["evaluation_id"], name: "index_evaluations_products_on_evaluation_id"
    t.index ["product_id"], name: "index_evaluations_products_on_product_id"
  end

  create_table "events", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "action", null: false
    t.string "user_agent"
    t.string "ip_address"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "auditable_type"
    t.bigint "auditable_id"
    t.index ["action", "auditable_type", "auditable_id"], name: "index_events_on_action_and_auditable"
    t.index ["auditable_type", "auditable_id"], name: "index_events_on_auditable"
    t.index ["metadata"], name: "index_events_on_metadata", using: :gin
    t.index ["user_id"], name: "index_events_on_user_id"
  end

  create_table "feature_flags", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "enabled", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_feature_flags_on_name", unique: true
  end

  create_table "guardian_relationships", force: :cascade do |t|
    t.bigint "guardian_id", null: false
    t.bigint "dependent_id", null: false
    t.string "relationship_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dependent_id"], name: "index_guardian_relationships_on_dependent_id"
    t.index ["guardian_id", "dependent_id"], name: "index_guardian_relationships_on_guardian_id_and_dependent_id", unique: true
    t.index ["guardian_id"], name: "index_guardian_relationships_on_guardian_id"
  end

  create_table "invoices", force: :cascade do |t|
    t.bigint "vendor_id", null: false
    t.datetime "start_date", null: false
    t.datetime "end_date", null: false
    t.decimal "total_amount", precision: 10, scale: 2, default: "0.0", null: false
    t.integer "status", default: 0, null: false
    t.datetime "payment_date"
    t.string "payment_reference"
    t.text "notes"
    t.string "invoice_number", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "check_number"
    t.datetime "check_issued_at"
    t.datetime "check_cashed_at"
    t.string "check_cashed_by"
    t.string "gad_invoice_reference"
    t.text "payment_notes"
    t.datetime "approved_at"
    t.datetime "payment_recorded_at"
    t.index ["approved_at"], name: "index_invoices_on_approved_at"
    t.index ["check_cashed_at"], name: "index_invoices_on_check_cashed_at"
    t.index ["check_issued_at"], name: "index_invoices_on_check_issued_at"
    t.index ["check_number"], name: "index_invoices_on_check_number"
    t.index ["gad_invoice_reference"], name: "index_invoices_on_gad_invoice_reference"
    t.index ["invoice_number"], name: "index_invoices_on_invoice_number", unique: true
    t.index ["payment_date"], name: "index_invoices_on_payment_date"
    t.index ["payment_recorded_at"], name: "index_invoices_on_payment_recorded_at"
    t.index ["start_date", "end_date"], name: "index_invoices_on_start_date_and_end_date"
    t.index ["status"], name: "index_invoices_on_status"
    t.index ["vendor_id", "status"], name: "index_invoices_on_vendor_id_and_status"
    t.index ["vendor_id"], name: "index_invoices_on_vendor_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "recipient_id", null: false
    t.bigint "actor_id"
    t.string "action"
    t.datetime "read_at"
    t.jsonb "metadata"
    t.string "notifiable_type", null: false
    t.bigint "notifiable_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "message_id"
    t.string "delivery_status"
    t.datetime "delivered_at"
    t.datetime "opened_at"
    t.boolean "audited", default: false, null: false
    t.index ["actor_id"], name: "index_notifications_on_actor_id"
    t.index ["audited"], name: "index_notifications_on_audited"
    t.index ["message_id"], name: "index_notifications_on_message_id"
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["recipient_id"], name: "index_notifications_on_recipient_id"
  end

  create_table "policies", force: :cascade do |t|
    t.string "key"
    t.integer "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_policies_on_key", unique: true
  end

  create_table "policy_changes", force: :cascade do |t|
    t.bigint "policy_id", null: false
    t.bigint "user_id", null: false
    t.integer "previous_value"
    t.integer "new_value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["policy_id"], name: "index_policy_changes_on_policy_id"
    t.index ["user_id"], name: "index_policy_changes_on_user_id"
  end

  create_table "print_queue_items", force: :cascade do |t|
    t.integer "letter_type", null: false
    t.integer "status", default: 0, null: false
    t.bigint "constituent_id", null: false
    t.bigint "application_id"
    t.bigint "admin_id"
    t.datetime "printed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["admin_id"], name: "index_print_queue_items_on_admin_id"
    t.index ["application_id"], name: "index_print_queue_items_on_application_id"
    t.index ["constituent_id"], name: "index_print_queue_items_on_constituent_id"
    t.check_constraint "letter_type >= 0 AND letter_type <= 11", name: "check_print_queue_items_on_letter_type"
  end

  create_table "products", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.decimal "price"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "manufacturer"
    t.string "model_number"
    t.text "features"
    t.text "compatibility_notes"
    t.string "documentation_url"
    t.text "device_types", default: [], array: true
    t.index ["device_types"], name: "index_products_on_device_types", using: :gin
  end

  create_table "products_users", id: false, force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "user_id", null: false
    t.index ["product_id"], name: "index_products_users_on_product_id"
    t.index ["user_id"], name: "index_products_users_on_user_id"
  end

  create_table "proof_reviews", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.bigint "admin_id", null: false
    t.integer "proof_type"
    t.integer "status"
    t.text "rejection_reason"
    t.integer "submission_method"
    t.datetime "reviewed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "notes"
    t.index ["admin_id", "created_at"], name: "index_proof_reviews_on_admin_id_and_created_at"
    t.index ["admin_id"], name: "index_proof_reviews_on_admin_id"
    t.index ["application_id", "proof_type", "created_at"], name: "idx_on_application_id_proof_type_created_at_4b8ffa7c5f"
    t.index ["application_id", "proof_type", "status"], name: "idx_on_application_id_proof_type_status_78cb268d0d"
    t.index ["application_id"], name: "index_proof_reviews_on_application_id"
    t.index ["reviewed_at"], name: "index_proof_reviews_on_reviewed_at"
    t.index ["status"], name: "index_proof_reviews_on_status"
  end

  create_table "recovery_requests", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "status"
    t.text "details"
    t.string "ip_address"
    t.text "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "resolved_at"
    t.integer "resolved_by_id"
    t.index ["user_id"], name: "index_recovery_requests_on_user_id"
  end

  create_table "role_capabilities", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "capability", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "capability"], name: "index_role_capabilities_on_user_id_and_capability", unique: true
    t.index ["user_id"], name: "index_role_capabilities_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "user_agent"
    t.string "ip_address"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "session_token"
    t.integer "failed_attempts", default: 0
    t.datetime "expires_at"
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["session_token"], name: "index_sessions_on_session_token", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "sms_credentials", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "phone_number", null: false
    t.datetime "last_sent_at", null: false
    t.text "code_digest"
    t.datetime "code_expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sms_credentials_on_user_id"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.text "error"
    t.text "backtrace"
    t.datetime "failed_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["failed_at"], name: "index_solid_queue_failed_executions_on_failed_at"
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id"
    t.index ["process_id"], name: "index_solid_queue_failed_executions_on_process_id"
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "solid_queue_tables", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "totp_credentials", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.text "secret", null: false
    t.string "nickname", null: false
    t.datetime "last_used_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_totp_credentials_on_user_id"
  end

  create_table "training_sessions", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.bigint "trainer_id", null: false
    t.datetime "scheduled_for"
    t.datetime "completed_at"
    t.integer "status", default: 0
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "reschedule_reason"
    t.datetime "cancelled_at"
    t.text "cancellation_reason"
    t.bigint "product_trained_on_id"
    t.text "no_show_notes"
    t.index ["application_id"], name: "index_training_sessions_on_application_id"
    t.index ["product_trained_on_id"], name: "index_training_sessions_on_product_trained_on_id"
    t.index ["trainer_id"], name: "index_training_sessions_on_trainer_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", limit: 510, null: false
    t.string "password_digest", limit: 500, null: false
    t.boolean "verified", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "type"
    t.string "first_name"
    t.string "middle_initial"
    t.string "last_name"
    t.string "phone", limit: 300
    t.string "ssn_last4", limit: 300
    t.string "physical_address_1", limit: 1000
    t.string "physical_address_2", limit: 1000
    t.string "city", limit: 500
    t.string "state", limit: 300
    t.string "zip_code", limit: 300
    t.string "county_of_residence"
    t.datetime "last_sign_in_at"
    t.string "last_sign_in_ip"
    t.integer "failed_attempts"
    t.datetime "locked_at"
    t.integer "status"
    t.boolean "valid_dcf", default: false
    t.boolean "previous_application_submitted", default: false
    t.boolean "newsletter_signup", default: false
    t.boolean "home_internet_service", default: false
    t.json "availability_schedule"
    t.integer "communication_preference"
    t.string "timezone"
    t.string "locale"
    t.string "preferred_means_of_communication"
    t.boolean "hearing_disability", default: false
    t.boolean "vision_disability", default: false
    t.boolean "speech_disability", default: false
    t.boolean "mobility_disability", default: false
    t.boolean "cognition_disability", default: false
    t.bigint "income_verified_by_id"
    t.bigint "evaluator_id"
    t.bigint "recipient_id"
    t.bigint "medical_provider_id"
    t.boolean "email_verified"
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.string "fax"
    t.string "business_name"
    t.string "business_tax_id"
    t.datetime "terms_accepted_at"
    t.integer "w9_status", default: 0, null: false
    t.integer "w9_rejections_count", default: 0, null: false
    t.datetime "last_w9_reminder_sent_at"
    t.boolean "force_password_change", default: false, null: false
    t.string "website_url"
    t.string "webauthn_id"
    t.boolean "needs_duplicate_review", default: false, null: false
    t.string "phone_type", default: "voice"
    t.text "date_of_birth"
    t.string "dependent_email", comment: "Optional email for dependents; if blank, uses guardian email"
    t.string "dependent_phone", comment: "Optional phone for dependents; if blank, uses guardian phone"
    t.integer "vendor_authorization_status"
    t.string "referral_source"
    t.index ["business_name"], name: "index_users_on_business_name"
    t.index ["business_tax_id"], name: "index_users_on_business_tax_id"
    t.index ["dependent_email"], name: "index_users_on_dependent_email"
    t.index ["dependent_phone"], name: "index_users_on_dependent_phone"
    t.index ["email"], name: "index_users_on_email"
    t.index ["email"], name: "index_users_on_email_unique", unique: true
    t.index ["evaluator_id"], name: "index_users_on_evaluator_id"
    t.index ["income_verified_by_id"], name: "index_users_on_income_verified_by_id"
    t.index ["medical_provider_id"], name: "index_users_on_medical_provider_id"
    t.index ["phone"], name: "index_users_on_phone", where: "(phone IS NOT NULL)"
    t.index ["phone"], name: "index_users_on_phone_unique", unique: true, where: "(phone IS NOT NULL)"
    t.index ["phone_type"], name: "index_users_on_phone_type"
    t.index ["recipient_id"], name: "index_users_on_recipient_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["type"], name: "index_users_on_type"
    t.index ["w9_rejections_count"], name: "index_users_on_w9_rejections_count", where: "((type)::text = 'Vendor'::text)"
    t.index ["w9_status"], name: "index_users_on_w9_status", where: "((type)::text = 'Vendor'::text)"
    t.index ["webauthn_id"], name: "index_users_on_webauthn_id", unique: true
  end

  create_table "voucher_transaction_products", force: :cascade do |t|
    t.bigint "voucher_transaction_id", null: false
    t.bigint "product_id", null: false
    t.integer "quantity", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_voucher_transaction_products_on_product_id"
    t.index ["voucher_transaction_id", "product_id"], name: "idx_on_voucher_txn_product"
    t.index ["voucher_transaction_id"], name: "index_voucher_transaction_products_on_voucher_transaction_id"
  end

  create_table "voucher_transactions", force: :cascade do |t|
    t.bigint "voucher_id", null: false
    t.bigint "vendor_id", null: false
    t.bigint "invoice_id"
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.integer "transaction_type", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.datetime "processed_at"
    t.text "notes"
    t.string "reference_number"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_id"], name: "index_voucher_transactions_on_invoice_id"
    t.index ["processed_at"], name: "index_voucher_transactions_on_processed_at"
    t.index ["reference_number"], name: "index_voucher_transactions_on_reference_number"
    t.index ["status"], name: "index_voucher_transactions_on_status"
    t.index ["transaction_type"], name: "index_voucher_transactions_on_transaction_type"
    t.index ["vendor_id", "status"], name: "index_voucher_transactions_on_vendor_id_and_status"
    t.index ["vendor_id"], name: "index_voucher_transactions_on_vendor_id"
    t.index ["voucher_id", "transaction_type"], name: "index_voucher_transactions_on_voucher_id_and_transaction_type"
    t.index ["voucher_id"], name: "index_voucher_transactions_on_voucher_id"
  end

  create_table "vouchers", force: :cascade do |t|
    t.string "code", null: false
    t.decimal "initial_value", precision: 10, scale: 2, null: false
    t.decimal "remaining_value", precision: 10, scale: 2, null: false
    t.integer "status", default: 0, null: false
    t.bigint "application_id", null: false
    t.bigint "vendor_id"
    t.datetime "issued_at"
    t.datetime "redeemed_at"
    t.datetime "last_used_at"
    t.bigint "invoice_id"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_vouchers_on_application_id"
    t.index ["code"], name: "index_vouchers_on_code", unique: true
    t.index ["invoice_id"], name: "index_vouchers_on_invoice_id"
    t.index ["issued_at"], name: "index_vouchers_on_issued_at"
    t.index ["status"], name: "index_vouchers_on_status"
    t.index ["vendor_id", "status"], name: "index_vouchers_on_vendor_id_and_status"
    t.index ["vendor_id"], name: "index_vouchers_on_vendor_id"
  end

  create_table "w9_reviews", force: :cascade do |t|
    t.bigint "vendor_id", null: false
    t.bigint "admin_id", null: false
    t.integer "status", default: 0, null: false
    t.integer "rejection_reason_code"
    t.text "rejection_reason"
    t.datetime "reviewed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["admin_id"], name: "index_w9_reviews_on_admin_id"
    t.index ["vendor_id"], name: "index_w9_reviews_on_vendor_id"
  end

  create_table "webauthn_credentials", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "external_id", null: false
    t.text "public_key", null: false
    t.string "nickname", null: false
    t.bigint "sign_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "authenticator_type"
    t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
    t.index ["user_id"], name: "index_webauthn_credentials_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "application_notes", "applications"
  add_foreign_key "application_notes", "users", column: "admin_id"
  add_foreign_key "application_status_changes", "applications"
  add_foreign_key "application_status_changes", "users"
  add_foreign_key "applications", "users"
  add_foreign_key "applications", "users", column: "income_verified_by_id"
  add_foreign_key "applications", "users", column: "managing_guardian_id"
  add_foreign_key "applications", "users", column: "medical_certification_verified_by_id"
  add_foreign_key "email_templates", "users", column: "updated_by_id"
  add_foreign_key "evaluations", "applications"
  add_foreign_key "evaluations", "users", column: "constituent_id"
  add_foreign_key "evaluations", "users", column: "evaluator_id"
  add_foreign_key "events", "users"
  add_foreign_key "guardian_relationships", "users", column: "dependent_id"
  add_foreign_key "guardian_relationships", "users", column: "guardian_id"
  add_foreign_key "invoices", "users", column: "vendor_id"
  add_foreign_key "notifications", "users", column: "actor_id"
  add_foreign_key "notifications", "users", column: "recipient_id"
  add_foreign_key "policy_changes", "policies"
  add_foreign_key "policy_changes", "users"
  add_foreign_key "print_queue_items", "applications"
  add_foreign_key "print_queue_items", "users", column: "admin_id"
  add_foreign_key "print_queue_items", "users", column: "constituent_id"
  add_foreign_key "proof_reviews", "applications"
  add_foreign_key "proof_reviews", "users", column: "admin_id"
  add_foreign_key "recovery_requests", "users"
  add_foreign_key "role_capabilities", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "sms_credentials", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_processes", column: "process_id", on_delete: :nullify
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "totp_credentials", "users"
  add_foreign_key "training_sessions", "applications"
  add_foreign_key "training_sessions", "products", column: "product_trained_on_id"
  add_foreign_key "training_sessions", "users", column: "trainer_id"
  add_foreign_key "users", "users", column: "evaluator_id"
  add_foreign_key "users", "users", column: "income_verified_by_id"
  add_foreign_key "users", "users", column: "medical_provider_id"
  add_foreign_key "users", "users", column: "recipient_id"
  add_foreign_key "voucher_transaction_products", "products"
  add_foreign_key "voucher_transaction_products", "voucher_transactions"
  add_foreign_key "voucher_transactions", "invoices"
  add_foreign_key "voucher_transactions", "users", column: "vendor_id"
  add_foreign_key "voucher_transactions", "vouchers"
  add_foreign_key "vouchers", "applications"
  add_foreign_key "vouchers", "invoices"
  add_foreign_key "vouchers", "users", column: "vendor_id"
  add_foreign_key "w9_reviews", "users", column: "admin_id"
  add_foreign_key "w9_reviews", "users", column: "vendor_id"
  add_foreign_key "webauthn_credentials", "users"
end
