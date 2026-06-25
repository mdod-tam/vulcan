# frozen_string_literal: true

require 'test_helper'

module Admin
  class EmailTemplatesLocaleTest < ActiveSupport::TestCase
    setup do
      unique_id = SecureRandom.hex(4)
      @template_text = create(
        :email_template, :text,
        name: "locale_template_text_#{unique_id}",
        subject: 'Text Subject',
        body: 'Text Body %<name>s'
      )
    end

    test 'locale defaults to en' do
      assert_equal 'en', @template_text.locale
    end

    test 'name + format + locale must be unique together' do
      duplicate = build(
        :email_template, :text,
        name: @template_text.name,
        body: @template_text.body,
        locale: 'en'
      )
      assert_not duplicate.valid?
      assert duplicate.errors[:name].any?
    end

    test 'same name and format can coexist with different locales' do
      es_template = build(
        :email_template, :text,
        name: @template_text.name,
        body: @template_text.body,
        locale: 'es'
      )
      assert es_template.valid?
    end

    test 'updating body flags counterpart locale as locale_needs_sync' do
      es_template = create(
        :email_template, :text,
        name: @template_text.name,
        body: @template_text.body,
        locale: 'es'
      )

      @template_text.update!(body: 'Updated body %<name>s.')
      es_template.reload

      assert es_template.locale_needs_sync?
    end

    test 'resolving out-of-sync locale does not flag counterpart' do
      en_template = @template_text
      es_template = create(
        :email_template, :text,
        name: en_template.name,
        body: 'Spanish body %<name>s',
        locale: 'es',
        locale_needs_sync: true
      )

      es_template.update!(body: 'Updated Spanish body %<name>s.')
      en_template.reload
      es_template.reload

      assert_not en_template.locale_needs_sync?
      assert_not es_template.locale_needs_sync?
    end

    test 'out-of-sync template allows enabled-only update' do
      @template_text.update_columns(locale_needs_sync: true)
      @template_text.reload

      assert @template_text.update!(enabled: false)
    end

    test 'template blocked from saving when locale_needs_sync is true and content is unchanged' do
      @template_text.update_column(:locale_needs_sync, true)
      @template_text.reload
      @template_text.description = 'New description only.'

      assert_not @template_text.valid?
      assert @template_text.errors[:base].any?
    end

    test 'locale_needs_sync? reflects renamed sync flag' do
      @template_text.update_columns(locale_needs_sync: true)
      @template_text.reload

      assert @template_text.locale_needs_sync?
    end

    test 'render_with_tracking renders hash variables' do
      admin = create(:admin)
      subject, body = @template_text.render_with_tracking({ 'name' => 'Alex' }, admin)

      assert_includes body, 'Alex'
      assert_includes subject, 'Text Subject'
    end
  end
end
