# frozen_string_literal: true

module Applications
  class TrainingLimitQueue
    Entry = Data.define(:application, :completed, :reserved, :remaining, :next_appointment)

    def entries
      applications = Application.status_approved
      sessions = TrainingSession.where(application_id: applications.select(:id))
      completed = sessions.completed_sessions.group(:application_id).count
      reserved = sessions.assigned_or_scheduled.group(:application_id).count
      counts = near_limit_counts(completed, reserved)
      applications = applications.where(id: counts.keys).includes(:user, :assigned_trainer, :income_proof_attachment, :disability_certification_attachment)
                                 .select { |application| application.service_window_active? && !application.unlimited_training_sessions? }
      build_entries(applications, counts, sessions)
    end

    private

    def near_limit_counts(completed, reserved)
      limit = Policy.max_training_sessions
      (completed.keys | reserved.keys).each_with_object({}) do |id, counts|
        done = completed.fetch(id, 0)
        booked = reserved.fetch(id, 0)
        remaining = limit - done - booked
        counts[id] = [done, booked, remaining] if remaining == 1 || (remaining.zero? && booked.positive?)
      end
    end

    def build_entries(applications, counts, sessions)
      sessions = sessions.where(application_id: applications.map(&:id))
      next_appointments = sessions.assigned_or_scheduled.where(scheduled_for: Time.current..).group(:application_id).minimum(:scheduled_for)
      entries = applications.map do |application|
        completed, reserved, remaining = counts.fetch(application.id)
        Entry.new(application, completed, reserved, remaining, next_appointments[application.id])
      end
      entries.sort_by { |entry| [entry.remaining, entry.next_appointment&.to_f || Float::INFINITY, entry.application.user.full_name, entry.application.id] }
    end
  end
end
