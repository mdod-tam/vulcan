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
  end
end
