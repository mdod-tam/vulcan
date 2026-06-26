# frozen_string_literal: true

require 'test_helper'

module Admin
  class EmailTemplatesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      FeatureFlag.disable!(:email_template_liquid)
    end

    teardown do
      FeatureFlag.disable!(:email_template_liquid)
    end

    test 'update saves EN only and flags ES as needing sync' do
      en_template = create(:email_template, :text,
                           name: 'dual_locale_update_en_test',
                           locale: 'en',
                           subject: 'EN Subject',
                           body: 'English body %<name>s',
                           description: 'English description',
                           locale_needs_sync: false)
      es_template = create(:email_template, :text,
                           name: en_template.name,
                           format: en_template.format,
                           locale: 'es',
                           subject: 'ES Subject',
                           body: 'Spanish body %<name>s',
                           description: 'Spanish description',
                           locale_needs_sync: false)

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
      assert es_template.locale_needs_sync?
    end

    test 'update saves ES only and flags EN as needing sync' do
      en_template = create(:email_template, :text,
                           name: 'dual_locale_update_es_test',
                           locale: 'en',
                           subject: 'EN Subject',
                           body: 'English body %<name>s',
                           description: 'English description',
                           locale_needs_sync: false)
      es_template = create(:email_template, :text,
                           name: en_template.name,
                           format: en_template.format,
                           locale: 'es',
                           subject: 'ES Subject',
                           body: 'Spanish body %<name>s',
                           description: 'Spanish description',
                           locale_needs_sync: false)

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
      assert en_template.locale_needs_sync?
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

    test 'create_counterpart copies syntax from source template' do
      FeatureFlag.enable!(:email_template_liquid)
      en_template = create(:email_template, :text,
                           name: 'create_counterpart_syntax_test',
                           locale: 'en',
                           syntax: :liquid,
                           subject: 'EN {{ name }}',
                           body: 'English body {{ name }}',
                           description: 'English description')

      post create_counterpart_admin_email_template_path(en_template), headers: default_headers

      es_template = EmailTemplate.find_by(name: en_template.name, format: en_template.format, locale: 'es')
      assert_not_nil es_template
      assert_equal 'liquid', es_template.syntax
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

    test 'mark_synced clears locale sync flag' do
      template = create(:email_template, :text,
                        name: "mark_synced_#{SecureRandom.hex(4)}",
                        locale_needs_sync: true)

      patch mark_synced_admin_email_template_path(template), headers: default_headers

      assert_redirected_to admin_email_template_path(template)
      template.reload
      assert_not template.locale_needs_sync?
    end

    test 'toggle_disabled changes enabled state without changing render version' do
      template = create(:email_template, :text, enabled: true)
      original_version = template.version

      patch toggle_disabled_admin_email_template_path(template), headers: default_headers

      assert_redirected_to admin_email_templates_path
      template.reload
      assert_not template.enabled
      assert_equal original_version, template.version
    end

    test 'update stores previous content when resolving out-of-sync locale template' do
      en_template = create(:email_template, :text,
                           name: 'out_of_sync_previous_version_test',
                           locale: 'en',
                           subject: 'EN Subject',
                           body: 'English body %<name>s',
                           description: 'English description',
                           locale_needs_sync: false)
      es_template = create(:email_template, :text,
                           name: en_template.name,
                           format: en_template.format,
                           locale: 'es',
                           subject: 'ES Subject',
                           body: 'Spanish body %<name>s',
                           description: 'Spanish description',
                           locale_needs_sync: true)

      patch admin_email_template_path(es_template), headers: default_headers, params: {
        locale: 'es',
        email_template: {
          subject: 'Updated ES Subject',
          body: 'Updated ES body %<name>s',
          description: 'Updated ES description'
        }
      }

      es_template.reload
      assert_equal 'ES Subject', es_template.previous_subject
      assert_equal 'Spanish body %<name>s', es_template.previous_body
      assert_equal 'Updated ES Subject', es_template.subject
      assert_equal 'Updated ES body %<name>s', es_template.body
      assert_not es_template.locale_needs_sync?
    end

    test 'show lists previous version without restore history' do
      template = create(:email_template, :text,
                        name: 'previous_version_show_test',
                        subject: 'Original subject',
                        body: 'Original body %<name>s')
      template.update!(subject: 'Updated subject', body: 'Updated body %<name>s')

      get admin_email_template_path(template), headers: default_headers

      assert_response :success
      assert_includes response.body, 'Previous Version'
      assert_includes response.body, 'Original subject'
      assert_includes response.body, 'Original body'
      assert_not_includes response.body, 'Restore'
    end

    test 'update permits syntax changes when Liquid flag is enabled' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :text,
                        name: 'syntax_update_test',
                        locale: 'en',
                        subject: 'Legacy %<name>s',
                        body: 'Legacy body %<name>s',
                        description: 'Legacy description')

      patch admin_email_template_path(template), headers: default_headers, params: {
        locale: 'en',
        email_template: {
          subject: 'Updated {{ name }}',
          body: 'Updated body {{ name }}',
          description: 'Updated description',
          syntax: 'liquid'
        }
      }

      assert_redirected_to edit_admin_email_template_path(template)
      assert_equal 'liquid', template.reload.syntax
    end

    test 'preview renders unsaved draft with selected Liquid syntax without persisting changes' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :text,
                        name: 'draft_preview_liquid_test',
                        locale: 'en',
                        subject: 'Saved %<name>s',
                        body: 'Saved body %<name>s',
                        description: 'Saved description',
                        variables: { 'required' => ['name'], 'optional' => [] })

      assert_no_changes -> { template.reload.attributes.slice('subject', 'body', 'description', 'syntax') } do
        patch preview_admin_email_template_path(template), headers: default_headers.merge('Turbo-Frame' => 'template-preview-en'), params: {
          locale: 'en',
          email_template: {
            subject: 'Draft {{ name }}',
            body: 'Draft body {{ name }}',
            description: 'Draft description',
            syntax: 'liquid'
          }
        }
      end

      assert_response :success
      assert_select 'turbo-frame#template-preview-en'
      assert_includes response.body, 'Draft Sample Name'
      assert_includes response.body, 'Draft body Sample Name'
      assert_includes response.body, 'Preview uses sample data and does not save changes.'
    end

    test 'preview returns friendly placeholder error for invalid Liquid draft' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :text,
                        name: 'draft_preview_invalid_liquid_test',
                        locale: 'en',
                        subject: 'Saved %<name>s',
                        body: 'Saved body %<name>s',
                        variables: { 'required' => ['name'], 'optional' => [] })

      assert_no_changes -> { template.reload.attributes.slice('subject', 'body', 'syntax') } do
        patch preview_admin_email_template_path(template), headers: default_headers.merge('Turbo-Frame' => 'template-preview-en'), params: {
          locale: 'en',
          email_template: {
            subject: 'Draft {{ name }}',
            body: 'Draft body {{ bad-path }}',
            description: template.description,
            syntax: 'liquid'
          }
        }
      end

      assert_response :unprocessable_content
      assert_select 'turbo-frame#template-preview-en'
      assert_includes response.body, 'Use variables from Insert Variable only'
      assert_no_match(/Invalid Liquid syntax|Liquid render failed/i, response.body)
    end

    test 'update shows friendly validation error for malformed Liquid syntax' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :text,
                        name: 'update_invalid_liquid_copy_test',
                        locale: 'en',
                        subject: 'Saved %<name>s',
                        body: 'Saved body %<name>s',
                        variables: { 'required' => ['name'], 'optional' => [] })

      patch admin_email_template_path(template), headers: default_headers, params: {
        locale: 'en',
        email_template: {
          subject: 'Draft {{ name }}',
          body: 'Draft body {{ unclosed',
          description: template.description,
          syntax: 'liquid'
        }
      }

      assert_response :unprocessable_content
      assert_equal 'legacy_percent', template.reload.syntax
      assert_includes response.body, 'This template has a placeholder problem. Use Insert Variable, then save again.'
      assert_no_match(/Invalid Liquid syntax|Liquid syntax error/i, response.body)
    end

    test 'update rejects invalid syntax param without raising' do
      template = create(:email_template, :text,
                        name: 'update_invalid_syntax_param_test',
                        locale: 'en',
                        subject: 'Saved %<name>s',
                        body: 'Saved body %<name>s',
                        variables: { 'required' => ['name'], 'optional' => [] })

      patch admin_email_template_path(template), headers: default_headers, params: {
        locale: 'en',
        email_template: {
          subject: 'Draft %<name>s',
          body: 'Draft body %<name>s',
          description: template.description,
          syntax: 'made_up'
        }
      }

      assert_response :unprocessable_content
      assert_equal 'legacy_percent', template.reload.syntax
      assert_includes response.body, 'Choose a valid placeholder style.'
      assert_no_match(/made_up.*valid syntax|ArgumentError/i, response.body)
    end

    test 'syntax-only update increments version and flags counterpart locale' do
      FeatureFlag.enable!(:email_template_liquid)
      en_template = create(:email_template, :text,
                           name: 'syntax_only_update_test',
                           locale: 'en',
                           subject: 'Plain subject',
                           body: 'Plain body',
                           previous_subject: 'Earlier subject',
                           previous_body: 'Earlier body',
                           variables: { 'required' => [], 'optional' => [] },
                           locale_needs_sync: false)
      es_template = create(:email_template, :text,
                           name: en_template.name,
                           format: en_template.format,
                           locale: 'es',
                           subject: 'Plain ES subject',
                           body: 'Plain ES body',
                           variables: { 'required' => [], 'optional' => [] },
                           locale_needs_sync: false)
      original_version = en_template.version
      original_previous_subject = en_template.previous_subject
      original_previous_body = en_template.previous_body

      patch admin_email_template_path(en_template), headers: default_headers, params: {
        locale: 'en',
        email_template: {
          subject: en_template.subject,
          body: en_template.body,
          description: en_template.description,
          syntax: 'liquid'
        }
      }

      assert_redirected_to edit_admin_email_template_path(en_template)
      assert_equal 'liquid', en_template.reload.syntax
      assert_equal original_version + 1, en_template.version
      assert_equal original_previous_subject, en_template.previous_subject
      assert_equal original_previous_body, en_template.previous_body
      assert es_template.reload.locale_needs_sync?
    end

    test 'update rejects liquid syntax when Liquid flag is disabled' do
      template = create(:email_template, :text,
                        name: 'syntax_update_flag_off_test',
                        locale: 'en',
                        subject: 'Legacy %<name>s',
                        body: 'Legacy body %<name>s',
                        description: 'Legacy description')

      patch admin_email_template_path(template), headers: default_headers, params: {
        locale: 'en',
        email_template: {
          subject: 'Updated {{ name }}',
          body: 'Updated body {{ name }}',
          description: 'Updated description',
          syntax: 'liquid'
        }
      }

      assert_response :unprocessable_content
      assert_equal 'legacy_percent', template.reload.syntax
      assert_includes response.body, 'Contact your administrator'
    end

    test 'edit hides liquid option for legacy template when Liquid flag is disabled' do
      template = create(:email_template, :text, name: "syntax_hidden_#{SecureRandom.hex(4)}")

      get edit_admin_email_template_path(template), headers: default_headers

      assert_response :success
      assert_select 'option[value="legacy_percent"]'
      assert_select 'option[value="liquid"]', count: 0
      assert_includes response.body, 'Liquid templates are not enabled yet. Contact your administrator'
    end

    test 'edit hides liquid option for html template when Liquid flag is enabled' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :html, name: "syntax_html_hidden_#{SecureRandom.hex(4)}")

      get edit_admin_email_template_path(template), headers: default_headers

      assert_response :success
      assert_select 'option[value="legacy_percent"]'
      assert_select 'option[value="liquid"]', count: 0
    end

    test 'update rejects liquid syntax for html templates' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :html,
                        name: 'syntax_update_html_test',
                        locale: 'en',
                        subject: 'Legacy %<name>s',
                        body: '<p>Legacy body %<name>s</p>',
                        description: 'Legacy description')

      patch admin_email_template_path(template), headers: default_headers, params: {
        locale: 'en',
        email_template: {
          subject: 'Updated {{ name }}',
          body: '<p>Updated body {{ name }}</p>',
          description: 'Updated description',
          syntax: 'liquid'
        }
      }

      assert_response :unprocessable_content
      assert_equal 'legacy_percent', template.reload.syntax
      assert_includes response.body, 'Liquid email templates are only available for text templates'
    end

    test 'show labels layout placeholder lines and keeps normal placeholder lines visible' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :text,
                        name: 'liquid_show_placeholder_lines_test',
                        syntax: :liquid,
                        subject: 'Hello {{ confirmation_url }}',
                        body: "{{ header_text }}\n{{ confirmation_url }}\nVisible content",
                        variables: { 'required' => %w[header_text confirmation_url], 'optional' => [] })

      get admin_email_template_path(template), headers: default_headers

      assert_response :success
      assert_select 'section[aria-labelledby="template-body-title"] pre', text: /Layout placeholder: \{\{ header_text \}\}/
      assert_select 'section[aria-labelledby="template-body-title"] pre', text: /\{\{ confirmation_url \}\}/
      assert_select 'section[aria-labelledby="template-body-title"] pre', text: /Visible content/
    end

    test 'preview sample data covers Liquid paths in subject and body' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :text,
                        name: 'liquid_preview_paths_test',
                        locale: 'en',
                        syntax: :liquid,
                        subject: 'Hello {{ constituent.first_name }}',
                        body: 'Application {{ application.id }} for {{ constituent.first_name }}',
                        variables: {
                          'required' => ['constituent.first_name', 'application.id'],
                          'optional' => []
                        })

      get new_test_email_admin_email_template_path(template), headers: default_headers

      assert_response :success
      assert_includes response.body, 'Hello Sample Constituent First Name'
      assert_includes response.body, 'Application Sample Application Id'
    end

    test 'preview rejects optional variables in Liquid drafts' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :text,
                        name: 'liquid_preview_optional_rejected_test',
                        locale: 'en',
                        subject: 'Saved %<name>s',
                        body: 'Saved body %<name>s',
                        variables: { 'required' => ['name'], 'optional' => ['optional_code'] })

      assert_no_changes -> { template.reload.attributes.slice('subject', 'body', 'syntax') } do
        patch preview_admin_email_template_path(template), headers: default_headers.merge('Turbo-Frame' => 'template-preview-en'), params: {
          locale: 'en',
          email_template: {
            subject: 'Draft {{ name }}',
            body: 'Draft body {{ optional_code }}',
            description: template.description,
            syntax: 'liquid'
          }
        }
      end

      assert_response :unprocessable_content
      assert_includes response.body, 'Liquid templates can only use Required Variables'
      assert_includes response.body, 'optional_code'
    end

    test 'send_test surfaces render error for existing Liquid row when flag is disabled' do
      FeatureFlag.enable!(:email_template_liquid)
      template = create(:email_template, :text,
                        name: 'liquid_send_flag_off_test',
                        locale: 'en',
                        syntax: :liquid,
                        subject: 'Hello {{ name }}',
                        body: 'Body {{ name }}')
      FeatureFlag.disable!(:email_template_liquid)

      post send_test_admin_email_template_path(template), headers: default_headers, params: {
        admin_test_email_form: {
          email: @admin.email,
          template_id: template.id
        }
      }

      assert_response :unprocessable_content
      assert_includes response.body, 'Contact your administrator'
    end

    test 'bulk_disable changes enabled templates and skips already disabled templates' do
      enabled_template = create(:email_template, :text, name: "bulk_disable_#{SecureRandom.hex(4)}", enabled: true)
      disabled_template = create(:email_template, :text, name: "bulk_disable_skip_#{SecureRandom.hex(4)}", enabled: false)
      disabled_updated_at = disabled_template.updated_at

      patch bulk_disable_admin_email_templates_path, headers: default_headers

      assert_not enabled_template.reload.enabled
      assert_not disabled_template.reload.enabled
      assert_equal disabled_updated_at.to_i, disabled_template.updated_at.to_i
    end

    test 'bulk_disable succeeds when a changed template is locale_needs_sync' do
      out_of_sync_template = create(:email_template, :text,
                                    name: "bulk_disable_oos_#{SecureRandom.hex(4)}",
                                    enabled: true,
                                    locale_needs_sync: true)

      assert_nothing_raised do
        patch bulk_disable_admin_email_templates_path, headers: default_headers
      end

      assert_not out_of_sync_template.reload.enabled
    end

    test 'bulk_enable changes disabled templates and skips already enabled templates' do
      disabled_template = create(:email_template, :text, name: "bulk_enable_#{SecureRandom.hex(4)}", enabled: false)
      enabled_template = create(:email_template, :text, name: "bulk_enable_skip_#{SecureRandom.hex(4)}", enabled: true)
      enabled_updated_at = enabled_template.updated_at

      patch bulk_enable_admin_email_templates_path, headers: default_headers

      assert disabled_template.reload.enabled
      assert enabled_template.reload.enabled
      assert_equal enabled_updated_at.to_i, enabled_template.updated_at.to_i
    end
  end
end
