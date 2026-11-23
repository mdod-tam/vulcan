# frozen_string_literal: true

module Reports
  class ApplicationActivity
    CHANNELS = { 'online' => 'Online', 'paper' => 'Paper entered by staff' }.freeze
    QUEUES = {
      proof_review: 'Proofs to review', certification_review: 'Certifications to review',
      waiting_certification: 'Waiting for certification'
    }.freeze
    STAGES = {
      waiting_proofs: 'Waiting for proofs', proof_review: 'Proof review',
      waiting_certification: 'Waiting for certification', certification_review: 'Certification review',
      waiting_evaluation: 'Waiting for evaluation'
    }.freeze

    def initialize(period)
      @period = period
    end

    def backlog
      QUEUES.to_h do |stage, label|
        values = @period.month_ends[0...-1].map do |day|
          history.fetch(stage).count { |span| span.started_at <= day && (span.ended_at.nil? || span.ended_at > day) }
        end
        [label, values.push(queues.fetch(stage).count)]
      end
    end

    def time_in_stages
      CHANNELS.to_h do |channel, label|
        averages = STAGES.keys.map do |stage|
          days = history.fetch(stage).filter_map do |span|
            next unless span.completed && span.channel == channel && @period.range.cover?(span.ended_at)

            (span.ended_at - span.started_at) / 1.day
          end
          (days.sum / days.size).round(1) if days.any?
        end
        [label, averages]
      end
    end

    def intake
      counts = submitted.group(:submission_method).count
      {
        CHANNELS.fetch('online') => counts.fetch('online', 0),
        CHANNELS.fetch('paper') => counts.fetch('paper', 0),
        'Other or unknown' => counts.except(*CHANNELS.keys).values.sum
      }
    end

    def current_stages
      scopes = {
        waiting_proofs: Application.awaiting_proofs.where.not(id: queues.fetch(:proof_review).select(:id)),
        waiting_certification: queues.fetch(:waiting_certification),
        waiting_evaluation: awaiting_evaluation
      }
      scopes.to_h { |stage, scope| [STAGES.fetch(stage), submitted.where(id: scope.select(:id)).count] }
    end

    def staff_contributions
      reviews = ProofReview.where(reviewed_at: @period.range)
                           .where.not(id: ProofReview.status_rejected.where(rejection_reason_code: 'none_provided').select(:id))
      proofs = reviews.where(proof_type: ProofReview.reviewable_proof_types).group(:admin_id).count
      certifications = reviews.proof_type_disability_certification.group(:admin_id).count
      evaluations = Evaluation.status_completed.where(appointment_completed_at: @period.range).group(:evaluator_id).count
      ids = proofs.keys | certifications.keys | evaluations.keys
      names = StaffNames.for(ids)
      ids.map { |id| [names.fetch(id), proofs.fetch(id, 0), certifications.fetch(id, 0), evaluations.fetch(id, 0)] }
         .sort_by { |name, *counts| [-counts.sum, name] }
    end

    private

    def submitted
      Submissions.within(@period.range)
    end

    def queues
      @queues ||= {
        proof_review: Application.staff_review_queue.awaiting_proof_review,
        certification_review: Application.certifications_needing_review,
        waiting_certification: Application.status_awaiting_dcf.where.not(disability_certification_status: :approved)
                                          .where.not(id: Application.certifications_needing_review.select(:id))
      }
    end

    def awaiting_evaluation
      procurement = Application.equipment_procurement_eligible.where(equipment_needs_initialized_at: nil)
                               .where.not(id: EquipmentNeed.select(:application_id))
                               .where.not(id: EquipmentItem.active.where.not(application_id: nil).select(:application_id))
      assigned = Application.status_approved.where(id: Evaluation.open_assigned.select(:application_id))
      procurement.or(assigned).or(Application.with_pending_evaluation_request)
    end

    def history
      @history ||= ApplicationReviewHistory.new(@period).call
    end
  end
end
