# frozen_string_literal: true

module Admin
  module UsersHelper
    # A role change changes the user's STI class, and with it dom_id. The access row keeps one id so a
    # Turbo Stream sent after the change still finds the row on the page.
    def access_dom_id(user, part)
      dom_id(user.becomes(User), part)
    end

    # Shown before an admin moves a vendor to another role; the conversion clears vendor-only fields.
    def vendor_conversion_warning
      'Converting this vendor to another role may lose their W9 and transaction history: their vendor details and ' \
        'W9 status are cleared, and their purchases and invoices will no longer belong to a vendor account. Convert anyway?'
    end

    # The roles an admin can choose in the users table. Read once per page, not once per row.
    def access_role_options
      @access_role_options ||= if FeatureFlag.enabled?(:vouchers_enabled)
                                 %w[Users::Administrator Users::Evaluator Users::Constituent Users::Vendor Users::Trainer]
                               else
                                 %w[Users::Administrator Users::Evaluator Users::Constituent Users::Trainer]
                               end
    end

    # One sentence per discipline the change would strand, naming the open work and where it goes.
    def access_impact_sentences(user, impact)
      impact.map do |entry|
        discipline, queue = entry.capability == 'can_train' ? %w[training Training] : %w[evaluation Evaluations]
        holding = if entry.open_count.positive?
                    "has #{pluralize(entry.open_count, "active #{entry.noun}")}"
                  else
                    "is the assigned trainer on #{pluralize(entry.application_ids.size, 'application')}"
                  end
        "#{user.full_name} #{holding}. Removing #{discipline} access sends them to #{queue} needing reassignment."
      end
    end

    def user_row_classes(user)
      classes = ['hover:bg-gray-50']
      classes << 'bg-warning-50 hover:bg-warning-100' if user.needs_duplicate_review

      if user.guardian? && !user.dependent? # Prioritize guardian if both (edge case)
        classes << 'bg-blue-100'
      elsif user.dependent?
        classes << 'bg-green-100'
      end

      classes.join(' ')
    end

    def inverse_relationship_label(relation)
      case relation.to_s.downcase
      when 'parent' then 'child'
      when 'guardian' then 'ward'
      else 'dependent'
      end
    end

    def paper_application_eligibility(user)
      paper_application_eligibility_results[user.id] ||= Applications::PaperApplicationEligibility.call(user, waiting_period_years: application_waiting_period_years)
    end

    def paper_application_eligibility_results
      @paper_application_eligibility_results ||= {}
    end

    def application_waiting_period_years
      @application_waiting_period_years ||= Policy.waiting_period_years
    end

    def latest_user_application(user)
      user.applications.max_by { |application| application.application_date || Date.new(1) }
    end

    def paper_application_ineligibility_reason(eligibility)
      case eligibility.reason
      when :blocking_application then 'Has active application'
      when :waiting_period then "Eligible after #{eligibility.eligible_after.to_date.strftime('%b %d, %Y')}"
      end
    end

    def paper_application_eligibility_badge(eligibility)
      label = eligibility.eligible? ? 'Eligible now' : paper_application_ineligibility_reason(eligibility)
      tag.span(label, class: "badge #{eligibility.eligible? ? 'badge-success' : 'badge-neutral'}")
    end
  end
end
