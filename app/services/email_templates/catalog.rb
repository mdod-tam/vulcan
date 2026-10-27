# frozen_string_literal: true

module EmailTemplates
  # The checked-in template files in db/seeds/email_templates. Loading a file creates its template.
  module Catalog
    DIR = Rails.root.join('db/seeds/email_templates').freeze

    def self.files
      DIR.glob('*.rb').sort
    end

    # Deletes every template and imports the checked-in files in one transaction. The new rows have new ids, so
    # mail captured under the old rows is refused by the delivery policy; pending letters are reconciled after commit.
    def self.replace!(actor:)
      EmailTemplate.transaction do
        replaced = EmailTemplate.delete_all
        files.each { |path| load path }
        report = Audit.run
        raise "Template import is incomplete: #{Audit.blocking_findings(report).join('; ')}" if Audit.blocking?(report)

        event = AuditEventService.log(action: 'email_templates_replaced', actor: actor, auditable: actor,
                                      metadata: { operation_id: SecureRandom.uuid, replaced: replaced, imported: EmailTemplate.count })
        raise 'The template replacement audit was not recorded' unless event

        Letters::ReconcilePendingJob.schedule
        EmailTemplate.count
      end
    end
  end
end
