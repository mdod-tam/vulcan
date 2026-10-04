# frozen_string_literal: true

module ConstituentPortal
  # Presents proof submissions and reviews in the constituent portal.
  class Activity
    include Comparable

    attr_reader :source, :created_at, :activity_type, :proof_type, :description, :details

    def self.from_events(application)
      proof_reviews = application.proof_reviews.to_a

      activities = proof_reviews.map do |review|
        from_proof_review(review)
      end

      # Portal submissions and paper attachments share this activity list.
      submission_events = application.events.where("action LIKE '%_proof_submitted' OR action LIKE '%_proof_attached'").to_a
      deduplicated_submissions = Applications::EventDeduplicationService.new.deduplicate(submission_events)

      deduplicated_submissions.each do |event|
        is_initial = initial_submission?(application, event)
        activities << from_submission_event(event, is_initial: is_initial)
      end

      activities.sort_by(&:created_at)
    end

    # Uses the canonical fingerprints and fixed one-minute buckets.
    def self.deduplicate_submissions(submissions)
      Applications::EventDeduplicationService.new.deduplicate(submissions)
    end

    def self.from_submission_event(event, is_initial: false)
      proof_type = event.metadata['proof_type']
      submission_method = event.metadata['submission_method'] || 'web'

      action_verb = event.action.include?('_attached') ? 'attached' : 'submitted'

      new(
        source: event,
        created_at: event.created_at,
        activity_type: is_initial ? :submission : :resubmission,
        proof_type: proof_type.to_sym,
        description: "#{proof_type.to_s.humanize} proof #{action_verb} via #{submission_method}"
      )
    end

    def self.from_proof_review(review)
      activity_type = review.status_approved? ? :approval : :rejection

      details = (review.rejection_reason.presence || review.notes if review.status_rejected? && (review.rejection_reason.present? || review.notes.present?))

      new(
        source: review,
        created_at: review.created_at,
        activity_type: activity_type,
        proof_type: review.proof_type.to_sym,
        description: "#{review.proof_type.to_s.humanize} proof #{review.status_approved? ? 'approved' : 'rejected'}",
        details: details
      )
    end

    def self.initial_submission?(application, event)
      proof_type = event.metadata['proof_type']
      action_names = ["#{proof_type}_proof_submitted", "#{proof_type}_proof_attached"]

      same_type_events = application.events
                                    .where(action: action_names)
                                    .order(created_at: :asc)

      same_type_events.first.id == event.id
    end

    def initialize(source:, created_at:, activity_type:, proof_type:, description:, details: nil) # rubocop:disable Metrics/ParameterLists
      @source = source
      @created_at = created_at
      @activity_type = activity_type
      @proof_type = proof_type
      @description = description
      @details = details
    end

    def <=>(other)
      created_at <=> other.created_at
    end

    def icon_class
      case activity_type
      when :submission, :resubmission
        'text-blue-600'
      when :approval
        'text-green-600'
      when :rejection
        'text-red-600'
      else
        'text-gray-500'
      end
    end

    def icon_symbol
      case activity_type
      when :submission, :resubmission
        '→'
      when :approval
        '✓'
      when :rejection
        '×'
      else
        '•'
      end
    end
  end
end
