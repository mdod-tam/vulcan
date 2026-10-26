# frozen_string_literal: true

require 'test_helper'

module EmailTemplates
  class CatalogTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @actor = create(:admin)
    end

    test 'replace imports every checked-in template, passes the audit, and records one audit event' do
      old_ids = EmailTemplate.pluck(:id)
      EmailTemplate.first.update_columns(body: 'Edited copy')

      count = Catalog.replace!(actor: @actor)

      assert_equal Catalog.files.size, count
      assert_not Audit.blocking?(Audit.run)
      assert_empty old_ids & EmailTemplate.pluck(:id), 'deleted template ids are never reused'
      assert_not_includes EmailTemplate.pluck(:body), 'Edited copy'
      event = Event.where(action: 'email_templates_replaced', auditable: @actor).order(:id).last
      assert_equal [old_ids.size, count], event.metadata.values_at('replaced', 'imported')
    end

    test 'a second replacement in the same process imports again' do
      Catalog.replace!(actor: @actor)
      EmailTemplate.find_by!(name: 'user_mailer_password_reset').update_columns(subject: 'Edited subject')

      Catalog.replace!(actor: @actor)

      assert_equal 'Account Access Instructions', EmailTemplate.find_by!(name: 'user_mailer_password_reset').subject
    end

    test 'pending letters are reconciled only after a successful replacement' do
      assert_enqueued_with(job: Letters::ReconcilePendingJob) { Catalog.replace!(actor: @actor) }
    end

    test 'a missing template file after the deletion keeps the previous catalog and queues nothing' do
      files = [*Catalog.files.first(3), Rails.root.join('db/seeds/email_templates/missing.rb')]
      Catalog.stubs(:files).returns(files)

      assert_replace_fails_and_keeps_catalog(LoadError)
    end

    test 'an unrecorded replacement audit keeps the previous catalog and queues nothing' do
      AuditEventService.stubs(:log).returns(nil)

      assert_replace_fails_and_keeps_catalog
    end

    test 'blocking audit findings keep the previous catalog and queue nothing' do
      Audit.stubs(:run).returns(missing_from_db: [{ name: 'x', locale: 'en', format: 'text' }], unexpected_in_db: [])

      assert_replace_fails_and_keeps_catalog
    end

    private

    def assert_replace_fails_and_keeps_catalog(error = StandardError)
      before = EmailTemplate.order(:id).pluck(:id, :body)

      assert_no_enqueued_jobs do
        assert_raises(error) { Catalog.replace!(actor: @actor) }
      end
      assert_equal before, EmailTemplate.order(:id).pluck(:id, :body)
    end
  end
end
