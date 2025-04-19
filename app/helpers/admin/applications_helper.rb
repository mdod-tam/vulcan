# frozen_string_literal: true

module Admin
  module ApplicationsHelper
    def medical_certification_link(application, style = :link)
      return nil unless application.medical_certification.attached?

      host = if Rails.env.production?
               MatVulcan::Application::PRODUCTION_HOST
             else
               # For non-production environments, use request.host if available
               Rails.application.routes.default_url_options[:host] || (defined?(request) && request.host)
             end

      url = Rails.application.routes.url_helpers.rails_blob_path(
        application.medical_certification,
        disposition: :inline,
        host: host
      )

      if style == :button
        # Use classes similar to other full-height buttons in the form
        link_to 'View Certification', url,
                target: '_blank',
                class: 'inline-flex justify-center py-2 px-4 border border-transparent shadow-sm text-sm font-medium rounded-md text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500', rel: 'noopener'
      else
        link_to 'View Certification', url,
                target: '_blank',
                class: 'text-blue-600 hover:text-blue-800 underline', rel: 'noopener'
      end
    end

    def medical_certification_submission_method(application)
      return 'unknown' unless application.medical_certification.attached?

      # Try to find submission method from metadata or related records
      if application.respond_to?(:medical_certification_submission_method) &&
         application.medical_certification_submission_method.present?
        return application.medical_certification_submission_method
      end

      # Check for status changes that might have the method
      status_change = ApplicationStatusChange.where(application_id: application.id)
                                             .where("metadata->>'change_type' = ? OR to_status = ?",
                                                    'medical_certification', 'received')
                                             .order(created_at: :desc)
                                             .first

      if status_change&.metadata.present? &&
         status_change.metadata['submission_method'].present?
        return status_change.metadata['submission_method']
      end

      # Default fallback
      'portal'
    end

    def format_rejection_reason(proof_type, application)
      proof_status_method = "#{proof_type}_proof_status"
      return nil unless application.respond_to?(proof_status_method)
      return nil unless application.send(proof_status_method) == 'rejected'

      proof_review = application.proof_reviews.where(proof_type: proof_type, status: 'rejected').order(created_at: :desc).first
      proof_review&.rejection_reason || 'Reason unavailable'
    end

    def format_review_status(proof_type, application)
      proof_status_method = "#{proof_type}_proof_status"
      return 'Pending' unless application.respond_to?(proof_status_method)

      status = application.send(proof_status_method)
      case status
      when 'approved'
        'Approved'
      when 'rejected'
        'Rejected'
      else
        'Pending'
      end
    end

    def proof_reviewer_actions_html(proof_type, application)
      # Already wrapped in if/else statement
      proof_status_method = "#{proof_type}_proof_status"
      case application.send(proof_status_method)
      when 'approved'
        link_to 'View Approved Proof',
                rails_blob_path(application.send("#{proof_type}_proof"), disposition: :inline),
                target: '_blank',
                class: 'btn btn-success btn-sm', rel: 'noopener'
      when 'pending'
        content_tag(:span, 'Manual review required',
                    class: 'badge badge-pill badge-warning')
      when 'rejected'
        latest_review = application.proof_reviews.where(proof_type: proof_type, status: 'rejected').order(created_at: :desc).first
        if latest_review
          content_tag(:div) do
            "Rejected on #{latest_review.created_at.strftime('%B %d, %Y')} " \
            "by #{latest_review.admin&.email || 'Unknown'}"
              .html_safe +
              content_tag(:div, class: 'mt-2') do
                link_to 'Review Again',
                        'javascript:;',
                        class: 'btn btn-primary btn-sm',
                        data: {
                          toggle: 'modal',
                          target: "##{proof_type}ProofReviewModal"
                        }
              end
          end
        else
          content_tag(:span, 'Rejected',
                      class: 'badge badge-pill badge-danger')
        end
      else
        'Unknown Status'
      end
    end

    def toggle_direction(column)
      # Check if the current sort column matches the link's column
      # and if the current direction is ascending.
      if params[:sort] == column.to_s && params[:direction] == 'asc'
        'desc' # If so, set the link's direction to descending
      else
        'asc'  # Otherwise, set the link's direction to ascending (default)
      end
    end

    # Get proof history in chronological order with deduplication
    def get_chronological_proof_history(application, proof_type)
      # Use the ConstituentPortal::Activity class to get deduplicated, chronological events
      all_activities = ConstituentPortal::Activity.from_events(application)

      # Filter to only activities for the specified proof type
      all_activities.select { |activity| activity.proof_type.to_s == proof_type.to_s }

      # Return in oldest-first order (already chronological from the from_events method)
    end
  end
end
