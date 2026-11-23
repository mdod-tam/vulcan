# frozen_string_literal: true

module Reports
  # Rebuilds known queue intervals from workflow transitions, document receipts and recorded decisions.
  class ApplicationReviewHistory
    Span = Data.define(:started_at, :ended_at, :channel, :completed)
    Point = Data.define(:at, :kind, :value, :proof, :blob_id)
    ACTIVE = ApplicationStatusManagement::ACTIVE_WORKFLOW_STATUSES
    TERMINAL = %w[archived rejected].freeze
    PROOF_TYPES = ProofReview.reviewable_proof_types.freeze
    ATTACHMENTS = PROOF_TYPES.index_by { |type| DocumentType.fetch(type).attachment_name.to_s }.freeze
    UPLOAD_ACTIONS = PROOF_TYPES.map { |type| "#{type}_proof_attached" }.freeze
    POINT_ORDER = %i[status received reviewed certification signed request evaluation].freeze

    def initialize(period)
      @period = period
    end

    def call
      spans = ApplicationActivity::STAGES.keys.index_with { [] }
      candidates.find_in_batches(batch_size: 250) do |batch|
        points = evidence(batch.map(&:id))
        batch.each do |application|
          add_initial_state(application, points[application.id])
          record_spans(application, points[application.id], spans)
        end
      end
      spans
    end

    private

    def candidates
      active = Application.staff_review_queue
      changed = Application.where(updated_at: @period.range)
      Application.submitted.where(id: active.select(:id)).or(Application.submitted.where(id: changed.select(:id)))
                 .select(:id, :status, :submission_method, :created_at, :document_signing_signed_at,
                         :fulfillment_type, :evaluation_requested_at, :equipment_source_evaluation_id)
    end

    def evidence(ids)
      points = Hash.new { |hash, id| hash[id] = [] }
      status_points(ids, points)
      proof_points(ids, points)
      Evaluation.status_completed.where(application_id: ids, report_submitted_at: ..@period.now)
                .pluck(:application_id, :report_submitted_at).each do |id, at|
        points[id] << point(at, :evaluation, nil)
      end
      points
    end

    def status_points(ids, points)
      changes = ApplicationStatusChange.where(application_id: ids, changed_at: ..@period.now).order(:changed_at, :id)
      changes.lifecycle.each do |change|
        points[change.application_id] << point(change.changed_at, :status, change.normalized_to_status,
                                               proof: change.normalized_from_status)
      end
      changes.where(change_type: :disability_certification).pluck(:application_id, :changed_at, :to_status).each do |id, at, status|
        points[id] << point(at, :certification, status)
      end
    end

    def proof_points(ids, points)
      audited = Set.new
      uploads = Event.where(auditable_type: 'Application', auditable_id: ids, action: UPLOAD_ACTIONS, created_at: ..@period.now)
                     .order(:created_at, :id)
      uploads.pluck(:auditable_id, :created_at, Arel.sql("metadata->>'proof_type'"),
                    Arel.sql("metadata->>'status'"), Arel.sql("metadata->>'blob_id'")).each do |id, at, proof, status, blob|
        next unless PROOF_TYPES.include?(proof) && blob.present?

        audited.add([id, proof, blob.to_i])
        points[id] << point(at, :received, status, proof:, blob_id: blob.to_i)
      end
      surviving = ActiveStorage::Attachment.where(record_type: 'Application', record_id: ids, name: ATTACHMENTS.keys, created_at: ..@period.now)
      surviving.pluck(:record_id, :created_at, :name, :blob_id).each do |id, at, name, blob|
        proof = ATTACHMENTS.fetch(name)
        next if audited.include?([id, proof, blob])

        points[id] << point(at, :received, 'not_reviewed', proof:, blob_id: blob)
      end
      ProofReview.where(application_id: ids, proof_type: PROOF_TYPES, reviewed_at: ..@period.now).chronological
                 .pluck(:application_id, :reviewed_at, :proof_type, :reviewed_blob_id).each do |id, at, proof, blob|
        points[id] << point(at, :reviewed, nil, proof:, blob_id: blob) if blob
      end
    end

    def add_initial_state(application, points)
      if application.submission_method_paper?
        initial = points.find { |entry| entry.kind == :status }&.proof || application.status
        points << point(application.created_at, :status, initial)
      end
      signed = application.document_signing_signed_at
      points << point(signed, :signed, nil) if signed && signed <= @period.now
      requested = application.evaluation_requested_at
      points << point(requested, :request, nil) if requested && requested <= @period.now
    end

    def record_spans(application, points, spans)
      state = { proofs: {}, certification: 'not_requested', status: 'draft', evaluated: false }
      open = {}
      points.sort_by { |entry| [entry.at, POINT_ORDER.index(entry.kind)] }.each do |entry|
        apply(state, entry)
        active = stages(state, application, entry.at)
        (open.keys - active).each do |stage|
          start = open.delete(stage)
          next if entry.at < @period.range.begin

          spans.fetch(stage) << Span.new(start, entry.at, application.submission_method, TERMINAL.exclude?(state[:status]))
        end
        active.each { |stage| open[stage] ||= entry.at }
      end
      open.each { |stage, start| spans.fetch(stage) << Span.new(start, nil, application.submission_method, false) }
    end

    def apply(state, entry)
      case entry.kind
      when :status then state[:status] = entry.value
      when :received
        state[:proofs][entry.proof] = entry.value == 'not_reviewed' ? entry.blob_id : nil
      when :reviewed
        state[:proofs].delete(entry.proof) if state[:proofs][entry.proof] == entry.blob_id
      when :certification then state[:certification] = entry.value
      when :signed then state[:certification] = 'received' unless state[:certification].in?(%w[approved rejected])
      when :evaluation then state[:evaluated] = true
      end
    end

    def stages(state, application, at)
      status = state.fetch(:status)
      cert = state.fetch(:certification)
      proofs = state.fetch(:proofs).compact
      [
        (:waiting_proofs if status.in?(%w[awaiting_proof reminder_sent]) && proofs.empty?),
        (:proof_review if reviewing_proofs?(status, proofs)),
        (:waiting_certification if status == 'awaiting_dcf' && %w[received approved].exclude?(cert)),
        (:certification_review if ACTIVE.include?(status) && cert == 'received'),
        (:waiting_evaluation if !state.fetch(:evaluated) && evaluation_needed?(status, application, at))
      ].compact
    end

    def reviewing_proofs?(status, proofs)
      return proofs.key?('income') if status == 'approved'

      ACTIVE.include?(status) && proofs.present?
    end

    def evaluation_needed?(status, application, at)
      return false unless status == 'approved'

      requested = application.evaluation_requested_at
      application.equipment_fulfillment? || application.equipment_source_evaluation_id? || (requested && requested <= at)
    end

    def point(at, kind, value, proof: nil, blob_id: nil)
      Point.new(at, kind, value, proof, blob_id)
    end
  end
end
