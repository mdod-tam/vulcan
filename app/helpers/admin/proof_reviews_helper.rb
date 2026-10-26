# frozen_string_literal: true

module Admin
  module ProofReviewsHelper
    def proof_review_label(status)
      case status.to_s
      when 'not_reviewed' then 'Needs Review'
      else status.to_s.humanize
      end
    end

    def review_status_label(status)
      case status.to_s
      when 'not_reviewed'
        'Needs Review'
      when 'approved'
        'Approved'
      when 'rejected'
        'Rejected'
      else
        status.to_s.titleize
      end
    end

    def proof_type_label(proof_type)
      case proof_type.to_s
      when 'income'
        'Proof of Income'
      when 'residency'
        'Proof of Residency'
      else
        proof_type.to_s.titleize
      end
    end

    def review_alert_class(days_waiting)
      if days_waiting >= 3
        'bg-danger-50 text-danger-700'
      elsif days_waiting >= 2
        'bg-warning-50 text-warning-700'
      else
        'bg-info-50 text-info-700'
      end
    end

    def days_waiting_message(application)
      return unless application.needs_review_since

      days = ((Time.current - application.needs_review_since) / 1.day).to_i
      if days >= 3
        "Waiting #{days} days - Urgent Review Needed"
      elsif days >= 2
        "Waiting #{days} days - Review Soon"
      else
        "Waiting #{days} #{'day'.pluralize(days)}"
      end
    end

    def proof_file_icon(proof)
      if proof.content_type.start_with?('image/')
        '<svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
              d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z" />
      </svg>'.html_safe
      else
        '<svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
              d="M7 21h10a2 2 0 002-2V9.414a1 1 0 00-.293-.707l-5.414-5.414A1 1 0 0012.586 3H7a2 2 0 00-2 2v14a2 2 0 002 2z" />
      </svg>'.html_safe
      end
    end

    def rejection_count_warning(application)
      remaining = 8 - application.total_rejections
      return if remaining > 3

      if remaining.zero?
        content_tag(:div, class: 'bg-danger-50 p-4 rounded-md') do
          content_tag(:p, class: 'text-sm text-danger-700') do
            "This application has reached the maximum number of rejections.
           Further rejections will archive the application."
          end
        end
      else
        content_tag(:div, class: 'bg-warning-50 p-4 rounded-md') do
          content_tag(:p, class: 'text-sm text-warning-700') do
            "Warning: #{remaining} #{'rejection'.pluralize(remaining)} remaining
           before application is automatically archived."
          end
        end
      end
    end
  end
end
