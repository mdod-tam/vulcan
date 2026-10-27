# frozen_string_literal: true

class ProofConsistencyCheckJob < ApplicationJob
  queue_as :low_priority

  def perform
    Rails.logger.info 'Starting proof consistency check job'

    inconsistent_applications = []
    total_checked = 0

    Application.find_each do |app|
      total_checked += 1

      if check_proof_consistency(app, :income_proof)
        inconsistent_applications << {
          id: app.id,
          type: 'income_proof',
          status: app.income_proof_status,
          attached: app.income_proof.attached?
        }
      end

      if check_proof_consistency(app, :residency_proof)
        inconsistent_applications << {
          id: app.id,
          type: 'residency_proof',
          status: app.residency_proof_status,
          attached: app.residency_proof.attached?
        }
      end
    end

    if inconsistent_applications.any?
      log_inconsistencies(inconsistent_applications, total_checked)
      notify_admins(inconsistent_applications) if Rails.env.production?
    else
      Rails.logger.info "Proof consistency check completed: No inconsistencies found in #{total_checked} applications"
    end
  end

  private

  def check_proof_consistency(app, proof_type)
    status_method = "#{proof_type}_status"
    status = app.send(status_method)
    attached = app.send(proof_type).attached?

    # Inconsistent: approved with no attachment, or attached but still not_reviewed.
    if (status == 'approved' && !attached) ||
       (attached && status == 'not_reviewed')
      Rails.logger.warn "Inconsistent proof state for application #{app.id}: " \
                        "#{proof_type} status is '#{status}' but attached? is #{attached}"
      return true
    end

    false
  end

  def log_inconsistencies(inconsistencies, total_checked)
    Rails.logger.warn "Proof consistency check found #{inconsistencies.size} inconsistencies in #{total_checked} applications"

    grouped = inconsistencies.group_by { |inc| inc[:type] }

    grouped.each do |type, issues|
      approved_missing = issues.count { |i| i[:status] == 'approved' && !i[:attached] }
      attached_not_reviewed = issues.count { |i| i[:attached] && i[:status] == 'not_reviewed' }

      Rails.logger.warn "#{type}: #{issues.size} total issues " \
                        "(#{approved_missing} approved without attachment, " \
                        "#{attached_not_reviewed} attached but not reviewed)"
    end
  end
end
