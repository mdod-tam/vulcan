# frozen_string_literal: true

class BackfillEvaluationReportSubmittedAt < ActiveRecord::Migration[8.1]
  def up
    # The report writer records this event after saving completion, in the same transaction.
    # Only restore its recorded time; scheduled dates and later edits do not prove submission.
    execute <<~SQL.squish
      UPDATE evaluations
      SET report_submitted_at = completions.submitted_at
      FROM (
        SELECT evaluations.id AS evaluation_id, MIN(events.created_at) AS submitted_at
        FROM evaluations
        INNER JOIN events ON events.auditable_type = 'Evaluation'
          AND events.auditable_id = evaluations.id
        WHERE evaluations.status = 3
          AND evaluations.report_submitted_at IS NULL
          AND events.action = 'evaluation_completed'
          AND events.metadata->>'evaluation_id' = evaluations.id::text
          AND events.metadata->>'application_id' = evaluations.application_id::text
        GROUP BY evaluations.id
      ) AS completions
      WHERE evaluations.id = completions.evaluation_id
        AND evaluations.status = 3
        AND evaluations.report_submitted_at IS NULL
    SQL
  end

  def down
    # Preserve restored history: a rollback cannot distinguish it from a later report submission.
  end
end
