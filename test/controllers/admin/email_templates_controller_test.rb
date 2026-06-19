# frozen_string_literal: true

require 'test_helper'

module Admin
  class EmailTemplatesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'update saves EN only and flags ES as needing sync' do
      en_template = create(:email_template, :text,
                           name: 'dual_locale_update_en_test',
                           locale: 'en',
                           subject: 'EN Subject',
                           body: 'English body %<name>s',
                           description: 'English description',
                           needs_sync: false)
      es_template = create(:email_template, :text,
                           name: en_template.name,
                           format: en_template.format,
                           locale: 'es',
                           subject: 'ES Subject',
                           body: 'Spanish body %<name>s',
                           description: 'Spanish description',
                           needs_sync: false)

      patch admin_email_template_path(en_template), headers: default_headers, params: {
        locale: 'en',
        email_template: {
          subject: 'Updated EN Subject',
          body: 'Updated EN body %<name>s',
          description: 'Updated EN description'
        }
      }

      assert_redirected_to edit_admin_email_template_path(en_template)
      en_template.reload
      es_template.reload

      assert_equal 'Updated EN Subject', en_template.subject
      assert_equal 'ES Subject', es_template.subject
      assert es_template.needs_sync?

      snapshot = en_template.email_template_snapshots.order(:snapshot_number).last
      assert_not_nil snapshot
      assert_equal 'admin_edit', snapshot.change_source
      assert_equal 'Updated EN Subject', snapshot.subject
    end

    test 'update saves ES only and flags EN as needing sync' do
      en_template = create(:email_template, :text,
                           name: 'dual_locale_update_es_test',
                           locale: 'en',
                           subject: 'EN Subject',
                           body: 'English body %<name>s',
                           description: 'English description',
                           needs_sync: false)
      es_template = create(:email_template, :text,
                           name: en_template.name,
                           format: en_template.format,
                           locale: 'es',
                           subject: 'ES Subject',
                           body: 'Spanish body %<name>s',
                           description: 'Spanish description',
                           needs_sync: false)

      patch admin_email_template_path(es_template), headers: default_headers, params: {
        locale: 'es',
        email_template: {
          subject: 'Updated ES Subject',
          body: 'Updated ES body %<name>s',
          description: 'Updated ES description'
        }
      }

      assert_redirected_to edit_admin_email_template_path(es_template)
      en_template.reload
      es_template.reload

      assert_equal 'EN Subject', en_template.subject
      assert_equal 'Updated ES Subject', es_template.subject
      assert en_template.needs_sync?
    end

    test 'create_counterpart creates missing ES template from EN' do
      en_template = create(:email_template, :text,
                           name: 'create_counterpart_test',
                           locale: 'en',
                           subject: 'EN Subject',
                           body: 'English body %<name>s',
                           description: 'English description')

      assert_difference -> { EmailTemplate.where(name: en_template.name, format: en_template.format, locale: 'es').count }, +1 do
        post create_counterpart_admin_email_template_path(en_template), headers: default_headers
      end

      assert_redirected_to edit_admin_email_template_path(en_template)

      es_template = EmailTemplate.find_by(name: en_template.name, format: en_template.format, locale: 'es')
      assert_not_nil es_template
      assert_equal en_template.subject, es_template.subject
      assert_equal en_template.body, es_template.body
      assert_equal en_template.description, es_template.description
    end

    test 'create_counterpart returns already exists notice when counterpart exists' do
      en_template = create(:email_template, :text,
                           name: 'create_counterpart_exists_test',
                           locale: 'en',
                           subject: 'EN Subject',
                           body: 'English body %<name>s')
      create(:email_template, :text,
             name: en_template.name,
             format: en_template.format,
             locale: 'es',
             subject: 'ES Subject',
             body: 'Spanish body %<name>s')

      assert_no_difference -> { EmailTemplate.where(name: en_template.name, format: en_template.format, locale: 'es').count } do
        post create_counterpart_admin_email_template_path(en_template), headers: default_headers
      end

      assert_redirected_to edit_admin_email_template_path(en_template)
      assert_equal 'ES template already exists.', flash[:notice]
    end

    test 'toggle_disabled records snapshot' do
      template = create(:email_template, :text, enabled: true)

      assert_difference -> { template.email_template_snapshots.count }, +2 do
        patch toggle_disabled_admin_email_template_path(template), headers: default_headers
      end

      prior = template.email_template_snapshots.order(:snapshot_number).first
      snapshot = template.email_template_snapshots.order(:snapshot_number).last
      assert_equal 'baseline', prior.change_source
      assert_equal true, prior.enabled
      assert_equal false, snapshot.enabled
      assert_equal 'admin_edit', snapshot.change_source
    end

    test 'update records snapshot when resolving out-of-sync locale template' do
      en_template = create(:email_template, :text,
                           name: 'out_of_sync_snapshot_test',
                           locale: 'en',
                           subject: 'EN Subject',
                           body: 'English body %<name>s',
                           description: 'English description',
                           needs_sync: false)
      es_template = create(:email_template, :text,
                           name: en_template.name,
                           format: en_template.format,
                           locale: 'es',
                           subject: 'ES Subject',
                           body: 'Spanish body %<name>s',
                           description: 'Spanish description',
                           needs_sync: true,
                           locale_needs_sync: true)

      assert_difference -> { es_template.email_template_snapshots.count }, +2 do
        patch admin_email_template_path(es_template), headers: default_headers, params: {
          locale: 'es',
          email_template: {
            subject: 'Updated ES Subject',
            body: 'Updated ES body %<name>s',
            description: 'Updated ES description'
          }
        }
      end

      snapshot = es_template.email_template_snapshots.order(:snapshot_number).last
      prior = es_template.email_template_snapshots.order(:snapshot_number).first
      assert_equal 'baseline', prior.change_source
      assert_equal 'ES Subject', prior.subject
      assert_equal 'Updated ES Subject', snapshot.subject
      assert_equal 'Updated ES body %<name>s', snapshot.body
    end

    test 'bulk_disable snapshots only templates that change enabled state' do
      enabled_template = create(:email_template, :text, name: "bulk_disable_#{SecureRandom.hex(4)}", enabled: true)
      disabled_template = create(:email_template, :text, name: "bulk_disable_skip_#{SecureRandom.hex(4)}", enabled: false)

      patch bulk_disable_admin_email_templates_path, headers: default_headers

      assert_not enabled_template.reload.enabled
      assert_not disabled_template.reload.enabled
      assert enabled_template.email_template_snapshots.count >= 2
      assert_not disabled_template.email_template_snapshots.exists?
    end

    test 'bulk_disable succeeds when a changed template is locale_needs_sync' do
      out_of_sync_template = create(:email_template, :text,
                                    name: "bulk_disable_oos_#{SecureRandom.hex(4)}",
                                    enabled: true,
                                    locale_needs_sync: true,
                                    needs_sync: true)

      assert_nothing_raised do
        patch bulk_disable_admin_email_templates_path, headers: default_headers
      end

      assert_not out_of_sync_template.reload.enabled
      assert out_of_sync_template.email_template_snapshots.exists?
    end
  end
end
