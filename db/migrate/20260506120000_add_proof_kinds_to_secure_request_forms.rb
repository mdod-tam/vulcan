# frozen_string_literal: true

class AddProofKindsToSecureRequestForms < ActiveRecord::Migration[8.0]
  SECURE_REQUEST_KIND_CONSTRAINT = :secure_request_forms_kind_check
  PRINT_QUEUE_LETTER_TYPE_CONSTRAINT = :check_print_queue_items_on_letter_type
  PROOF_REVIEW_SUBMISSION_METHOD_CONSTRAINT = :proof_reviews_submission_method_check

  def up
    widen_secure_request_form_kind_check!('kind IN (0, 1, 2, 3)')
    add_proof_resubmission_indexes!
    widen_print_queue_letter_type_check!(upper_bound: 13)
    widen_proof_review_submission_method_check!('submission_method IS NULL OR submission_method IN (0, 1, 2, 3, 4)')
  end

  def down
    remove_proof_resubmission_indexes!
    widen_secure_request_form_kind_check!('kind = 0')
    widen_print_queue_letter_type_check!(upper_bound: 12)
    widen_proof_review_submission_method_check!('submission_method IS NULL OR submission_method IN (0, 1, 2, 3)')
  end

  private

  def widen_secure_request_form_kind_check!(expression)
    remove_check_constraint :secure_request_forms,
                            name: SECURE_REQUEST_KIND_CONSTRAINT,
                            if_exists: true
    add_check_constraint :secure_request_forms,
                         expression,
                         name: SECURE_REQUEST_KIND_CONSTRAINT
  end

  def add_proof_resubmission_indexes!
    add_index :secure_request_forms,
              %i[application_id kind recipient_id],
              unique: true,
              where: 'status = 0 AND kind = 1',
              name: 'idx_secure_request_forms_one_active_id_proof_recipient'
    add_index :secure_request_forms,
              %i[application_id kind recipient_id],
              unique: true,
              where: 'status = 0 AND kind = 2',
              name: 'idx_secure_request_forms_one_active_residency_proof_recipient'
    add_index :secure_request_forms,
              %i[application_id kind recipient_id],
              unique: true,
              where: 'status = 0 AND kind = 3',
              name: 'idx_secure_request_forms_one_active_income_proof_recipient'
  end

  def remove_proof_resubmission_indexes!
    remove_index :secure_request_forms,
                 name: 'idx_secure_request_forms_one_active_id_proof_recipient',
                 if_exists: true
    remove_index :secure_request_forms,
                 name: 'idx_secure_request_forms_one_active_residency_proof_recipient',
                 if_exists: true
    remove_index :secure_request_forms,
                 name: 'idx_secure_request_forms_one_active_income_proof_recipient',
                 if_exists: true
  end

  def widen_print_queue_letter_type_check!(upper_bound:)
    remove_check_constraint :print_queue_items,
                            name: PRINT_QUEUE_LETTER_TYPE_CONSTRAINT,
                            if_exists: true
    add_check_constraint :print_queue_items,
                         "letter_type >= 0 AND letter_type <= #{upper_bound}",
                         name: PRINT_QUEUE_LETTER_TYPE_CONSTRAINT
  end

  def widen_proof_review_submission_method_check!(expression)
    remove_check_constraint :proof_reviews,
                            name: PROOF_REVIEW_SUBMISSION_METHOD_CONSTRAINT,
                            if_exists: true
    add_check_constraint :proof_reviews,
                         expression,
                         name: PROOF_REVIEW_SUBMISSION_METHOD_CONSTRAINT
  end
end
