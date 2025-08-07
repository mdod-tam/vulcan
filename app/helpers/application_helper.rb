# frozen_string_literal: true

# Application helper methods for common view functionality and formatting.
module ApplicationHelper
  include ConstituentPortal::ActivityHelper
  include ActiveStorageHelper
  include Pagy::Frontend
  include BadgeHelper

  def flash_class_for(flash_type)
    case flash_type.to_s
    when 'notice', 'success' then 'bg-green-100 border border-green-400 text-green-700'
    when 'alert', 'error' then 'bg-red-100 border border-red-400 text-red-700'
    when 'warning' then 'bg-yellow-100 border border-yellow-400 text-yellow-700'
    when 'info' then 'bg-blue-100 border border-blue-400 text-blue-700'
    else 'bg-gray-100 border border-gray-400 text-gray-700'
    end
  end

  def dashboard_path_for(user)
    return root_path unless user

    case user.type
    when 'Admin' then admin_applications_path
    when 'Evaluator' then evaluator_root_path
    when 'Users::Vendor' then vendor_root_path
    else root_path
    end
  end

  def application_status_badge(application)
    content_tag(:span,
                badge_label_for(:application, application.status),
                class: "px-3 py-2 text-sm font-medium rounded-full whitespace-nowrap inline-flex items-center justify-center #{badge_class_for(
                  :application, application.status
                )}")
  end

  def proof_status_badge(_proof_type, status)
    content_tag(:span,
                badge_label_for(:proof, status),
                class: "px-3 py-2 text-sm font-medium rounded-full whitespace-nowrap inline-flex items-center justify-center #{badge_class_for(
                  :proof, status
                )}")
  end

  def evaluation_status_badge(evaluation)
    content_tag(:span,
                badge_label_for(:evaluation, evaluation.status),
                class: "px-3 py-2 text-sm font-medium rounded-full whitespace-nowrap inline-flex items-center justify-center #{badge_class_for(
                  :evaluation, evaluation.status
                )}")
  end

  def training_session_status_badge(session)
    content_tag(:span,
                badge_label_for(:training_session, session.status),
                class: "px-3 py-2 text-sm font-medium rounded-full whitespace-nowrap inline-flex items-center justify-center #{badge_class_for(
                  :training_session, session.status
                )}")
  end

  def medical_certification_status_badge(application)
    content_tag(:span,
                application.medical_certification_status.titleize,
                class: "px-3 py-2 text-sm font-medium rounded-full whitespace-nowrap inline-flex items-center justify-center #{badge_class_for(
                  :certification, application.medical_certification_status
                )}")
  end

  # Determines the appropriate proof review button text based on proof status
  # @param application [Application] The application instance
  # @param proof_type [String] The type of proof ("income" or "residency")
  # @return [String] The appropriate button text
  def proof_review_button_text(application, proof_type)
    latest_review, latest_audit = latest_review_and_audit(application, proof_type)

    if latest_review&.status_rejected?
      if latest_audit && latest_review && latest_audit.created_at > latest_review.created_at
        'Review Resubmitted Proof'
      else
        'Review Rejected Proof'
      end
    else
      'Review Proof'
    end
  end

  # Determines the appropriate CSS classes for the proof review button
  # @param application [Application] The application instance
  # @param proof_type [String] The type of proof ("income" or "residency")
  # @return [String] The appropriate CSS class string for the button
  def proof_review_button_class(application, proof_type)
    latest_review, latest_audit = latest_review_and_audit(application, proof_type)

    if latest_review&.status_rejected?
      if latest_audit && latest_review && latest_audit.created_at > latest_review.created_at
        # Resubmitted proof - keep blue
        'bg-blue-600 hover:bg-blue-700'
      else
        # Rejected proof - use red
        'bg-red-600 hover:bg-red-700'
      end
    else
      # Initial review - keep blue
      'bg-blue-600 hover:bg-blue-700'
    end
  end

  # Alias for the constituent portal proof route helper
  # The actual generated helper is constituent_portal_application_new_proof_path
  # but views and tests expect new_proof_constituent_portal_application_path
  def new_proof_constituent_portal_application_path(application, **)
    constituent_portal_application_new_proof_path(application, **)
  end

  private

  # Fetches the latest proof review and submission audit for a given proof type
  # @param application [Application] The application instance
  # @param type [String] The proof type ('income' or 'residency')
  # @return [Array<ProofReview, Event>] An array containing the latest review and audit, or nils
  def latest_review_and_audit(application, type)
    latest_review = application.proof_reviews.where(proof_type: type).order(created_at: :desc).first
    latest_audit = application.events.where(action: 'proof_submitted').where("metadata->>'proof_type' = ?", type).order(created_at: :desc).first
    [latest_review, latest_audit]
  end
end
