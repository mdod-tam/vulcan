# frozen_string_literal: true

module ConstituentPortal
  # Presents proof submissions and reviews in the constituent portal.
  class Activity
    include Comparable

    attr_reader :source, :created_at, :activity_type, :proof_type, :description, :details

    def self.from_events(application)
      proof_reviews = application.proof_reviews.chronological.to_a

      activities = proof_reviews.map do |review|
        from_proof_review(review)
      end

      # Portal submissions and paper attachments share this activity list.
      submission_events = application.events.where("action LIKE '%_proof_attached'").to_a
      deduplicated_submissions = Applications::EventDeduplicationService.new.deduplicate(submission_events)

      deduplicated_submissions.each do |event|
        is_initial = initial_submission?(application, event)
        activities << from_submission_event(event, is_initial: is_initial)
      end

      activities.sort_by { |activity| [activity.created_at, activity.source.id] }
    end

    # Uses the canonical fingerprints and fixed one-minute buckets.
    def self.deduplicate_submissions(submissions)
      Applications::EventDeduplicationService.new.deduplicate(submissions)
    end

    def self.from_submission_event(event, is_initial: false)
      proof_type = event.metadata['proof_type']
      submission_method = event.metadata['submission_method'] || 'web'

      new(
        source: event,
        created_at: event.created_at,
        activity_type: is_initial ? :submission : :resubmission,
        proof_type: proof_type.to_sym,
        description: I18n.t("constituent_portal.activity.attached_via.#{submission_method}",
                            proof: proof_label(proof_type), default: :'constituent_portal.activity.attached')
      )
    end

    def self.from_proof_review(review)
      activity_type = review.status_approved? ? :approval : :rejection

      details = (review.rejection_reason.presence || review.notes if review.status_rejected? && (review.rejection_reason.present? || review.notes.present?))

      new(
        source: review,
        created_at: review.reviewed_at,
        activity_type: activity_type,
        proof_type: review.proof_type.to_sym,
        description: I18n.t("constituent_portal.activity.reviews.#{review.proof_type}.#{review.status}",
                            default: :"constituent_portal.activity.#{review.status}", proof: proof_label(review.proof_type)),
        details: details
      )
    end

    # The secure-form proof names, so the portal and the messages call each proof the same thing.
    def self.proof_label(proof_type)
      I18n.t("secure_proof_forms.proof_types.#{proof_type}", default: proof_type.to_s.humanize.downcase).upcase_first
    end
    private_class_method :proof_label

    def self.initial_submission?(application, event)
      proof_type = event.metadata['proof_type']

      same_type_events = application.events
                                    .where(action: "#{proof_type}_proof_attached")
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
