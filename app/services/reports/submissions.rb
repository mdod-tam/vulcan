# frozen_string_literal: true

module Reports
  module Submissions
    def self.within(range)
      transitions = online_transitions.where(changed_at: range).select(:application_id)
      Application.where(id: transitions).or(Application.submission_method_paper.submitted.where(created_at: range))
    end

    def self.online_transitions
      ApplicationStatusChange.lifecycle.where(from_status: 'draft', to_status: 'in_progress')
    end
  end
end
