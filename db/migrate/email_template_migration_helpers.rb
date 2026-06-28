# frozen_string_literal: true

# Shared helpers for email template data migrations. Use a bare AR record
# instead of EmailTemplate so pending migrations stay safe when later PRs change
# model callbacks, validations, or column names (e.g. needs_sync rename in PR #176).
module EmailTemplateMigrationHelpers
  TEXT_EMAIL_FORMAT = 1

  class Record < ActiveRecord::Base
    self.table_name = 'email_templates'
  end

  private

  def delete_email_template_records!(scope)
    template_ids = scope.pluck(:id)
    return if template_ids.empty?

    delete_email_template_snapshots_for!(template_ids)
    scope.delete_all
  end

  # PR #176 adds email_template_snapshots with a non-cascading FK. Older-timestamp
  # migrations may still be pending after snapshots exist.
  def delete_email_template_snapshots_for!(template_ids)
    return unless connection.table_exists?(:email_template_snapshots)

    snapshot_table = connection.quote_table_name('email_template_snapshots')
    quoted_ids = template_ids.map { |id| connection.quote(id) }.join(', ')
    connection.execute("DELETE FROM #{snapshot_table} WHERE email_template_id IN (#{quoted_ids})")
  end

  def sync_email_template_variables!(name:, locale:, variables:)
    template = Record.find_by(name: name, format: TEXT_EMAIL_FORMAT, locale: locale)
    return unless template

    sync_column = locale_sync_column_name
    template.update_columns(
      variables: variables,
      sync_column => false,
      updated_at: Time.current
    )
  end

  def upsert_email_template_record!(name:, locale:, attributes:)
    template = Record.find_by(name: name, format: TEXT_EMAIL_FORMAT, locale: locale)
    sync_column = locale_sync_column_name
    now = Time.current

    row = {
      subject: attributes.fetch(:subject),
      description: attributes.fetch(:description),
      body: attributes.fetch(:body),
      variables: attributes.fetch(:variables),
      sync_column => false,
      updated_at: now
    }

    if template
      row[:version] = template.version.to_i + 1 if template.subject != row[:subject].to_s || template.body != row[:body].to_s
      template.update_columns(row)
    else
      Record.create!(
        row.merge(
          name: name,
          format: TEXT_EMAIL_FORMAT,
          locale: locale,
          version: 1,
          enabled: true,
          created_at: now
        )
      )
    end
  end

  # PR #176 renames needs_sync → locale_needs_sync for clarity
  def locale_sync_column_name
    connection.column_exists?(:email_templates, :locale_needs_sync) ? :locale_needs_sync : :needs_sync
  end
end
