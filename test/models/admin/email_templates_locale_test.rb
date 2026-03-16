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

    test 'updating body flags counterpart locale as needs_sync' do
      es_template = create(
        :email_template, :text,
        name: @template_text.name,
        body: @template_text.body,
        locale: 'es'
      )

      @template_text.update!(body: 'Updated body %<name>s.')
      es_template.reload

      assert es_template.needs_sync?
    end

    test 'template blocked from saving when needs_sync is true and content is unchanged' do
      @template_text.update_column(:needs_sync, true)
      @template_text.reload
      @template_text.description = 'New description only.'

      assert_not @template_text.valid?
      assert @template_text.errors[:base].any?
    end

    test 'template allowed to save when needs_sync is true but body is changing' do
      @template_text.update_column(:needs_sync, true)
      @template_text.reload

      assert @template_text.update(body: 'Fixed body %<name>s.')
      @template_text.reload
      assert_not @template_text.needs_sync?
    end
  end
end
