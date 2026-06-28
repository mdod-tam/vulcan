# frozen_string_literal: true

require 'test_helper'

module EmailTemplates
  class RendererTest < ActiveSupport::TestCase
    test 'legacy percent rendering preserves existing placeholder behavior' do
      # rubocop:disable Style/FormatStringToken
      template = create(
        :email_template,
        :text,
        subject: 'Hello %<name>s',
        body: 'Hi %{name}. Optional: %<nickname>s. Missing: %<unused>s',
        variables: { 'required' => ['name'], 'optional' => %w[nickname unused] },
        syntax: :legacy_percent
      )
      # rubocop:enable Style/FormatStringToken

      subject, body = template.render(name: 'Alex', nickname: 'Al')

      assert_equal 'Hello Alex', subject
      assert_equal 'Hi Alex. Optional: Al. Missing: ', body
    end

    test 'liquid renders exact allowed paths without passing root objects through' do
      template = create(
        :email_template,
        :text,
        subject: 'Hello {{ constituent.first_name }}',
        body: 'Application {{ application.id }} for {{ constituent.first_name }}',
        variables: { 'required' => ['constituent.first_name', 'application.id'], 'optional' => [] },
        syntax: :liquid
      )

      subject, body = template.render(
        constituent: { first_name: 'Alex', email: 'private@example.com' },
        application: { id: 123, internal_notes: 'do not expose' }
      )

      assert_equal 'Hello Alex', subject
      assert_equal 'Application 123 for Alex', body
      assert_not_includes body, 'private@example.com'
      assert_not_includes body, 'do not expose'
    end

    test 'liquid does not traverse arbitrary object roots' do
      user = create(:constituent, first_name: 'Alex')
      template = create(
        :email_template,
        :text,
        subject: 'Hello {{ user.first_name }}',
        body: 'Body {{ user.first_name }}',
        variables: { 'required' => ['user.first_name'], 'optional' => [] },
        syntax: :liquid
      )

      error = assert_raises(ArgumentError) do
        template.render(user: user)
      end

      assert_includes error.message, 'user.first_name'
    end

    test 'liquid rejects variables outside the exact allowlist' do
      template = build(
        :email_template,
        :text,
        subject: 'Hello {{ constituent.first_name }}',
        body: 'Email {{ constituent.email }}',
        variables: { 'required' => ['constituent.first_name'], 'optional' => [] },
        syntax: :liquid
      )

      assert_not template.valid?
      assert_includes template.errors[:body].join, 'constituent.email'
    end

    test 'liquid rejects tags and filters' do
      tagged = build(
        :email_template,
        :text,
        subject: 'Hello {{ name }}',
        body: '{% if name %}Hello{% endif %}',
        variables: { 'required' => ['name'], 'optional' => [] },
        syntax: :liquid
      )
      filtered = build(
        :email_template,
        :text,
        subject: 'Hello {{ name | upcase }}',
        body: 'Body {{ name }}',
        variables: { 'required' => ['name'], 'optional' => [] },
        syntax: :liquid
      )

      assert_not tagged.valid?
      assert_includes tagged.errors[:base].join, 'Only simple variable placeholders like {{ name }} are supported'
      assert_not filtered.valid?
      assert_includes filtered.errors[:base].join, 'Only simple variable placeholders like {{ name }} are supported'
    end

    test 'liquid rejects malformed syntax on save' do
      template = build(
        :email_template,
        :text,
        subject: 'Hello {{ name }}',
        body: 'Body {{ unclosed',
        variables: { 'required' => ['name'], 'optional' => [] },
        syntax: :liquid
      )

      assert_not template.valid?
      assert_includes template.errors[:base].join, 'Invalid Liquid syntax'
    end

    test 'liquid invalid path message points admins to Insert Variable' do
      template = build(
        :email_template,
        :text,
        subject: 'Hello {{ name }}',
        body: 'Body {{ bad-path }}',
        variables: { 'required' => ['name'], 'optional' => [] },
        syntax: :liquid
      )

      assert_not template.valid?
      assert_includes template.errors[:base].join, 'Use variables from Insert Variable only'
      assert_includes template.errors[:base].join, 'bad-path'
    end

    test 'liquid supports trim output delimiters' do
      template = create(
        :email_template,
        :text,
        subject: 'Hello {{- user.first_name -}}',
        body: 'Body {{- user.first_name -}}',
        variables: { 'required' => ['user.first_name'], 'optional' => [] },
        syntax: :liquid
      )

      subject, body = template.render(user: { first_name: 'Alex' })

      assert_equal 'HelloAlex', subject
      assert_equal 'BodyAlex', body
      assert_equal ['user.first_name'], template.extract_variables
    end

    test 'liquid rendering raises on missing referenced variables' do
      template = create(
        :email_template,
        :text,
        subject: 'Hello {{ name }}',
        body: 'Body {{ optional_code }}',
        variables: { 'required' => %w[name optional_code], 'optional' => [] },
        syntax: :liquid
      )

      error = assert_raises(ArgumentError) do
        template.render(name: 'Alex')
      end

      assert_includes error.message, 'optional_code'
    end

    test 'liquid save rejects optional variables in the template' do
      template = build(
        :email_template,
        :text,
        subject: 'Hello {{ name }}',
        body: 'Body {{ optional_code }}',
        variables: { 'required' => ['name'], 'optional' => ['optional_code'] },
        syntax: :liquid
      )

      assert_not template.valid?
      assert_includes template.errors[:body].join, 'Liquid templates can only use Required Variables'
      assert_includes template.errors[:body].join, 'optional_code'
    end

    test 'existing liquid templates remain savable for operational updates' do
      template = create(
        :email_template,
        :text,
        subject: 'Hello {{ name }}',
        body: 'Body {{ name }}',
        variables: { 'required' => ['name'], 'optional' => [] },
        syntax: :liquid
      )

      assert_nothing_raised do
        template.update!(description: 'Updated description')
      end
      assert_equal 'liquid', template.reload.syntax
      assert_equal 'Updated description', template.description
    end

    test 'liquid render rejects optional variables even when a row bypassed save validation' do
      template = build(
        :email_template,
        :text,
        subject: 'Hello {{ name }}',
        body: 'Body {{ optional_code }}',
        variables: { 'required' => ['name'], 'optional' => ['optional_code'] },
        syntax: :liquid
      )

      error = assert_raises(ArgumentError) do
        template.render(name: 'Alex', optional_code: 'ABC123')
      end

      assert_includes error.message, 'optional_code'
      assert_includes error.message, 'not available'
    end

    test 'liquid validation explains standard placeholders left behind' do
      template = build(
        :email_template,
        :text,
        subject: 'Hello %<name>s',
        body: 'Body %<name>s',
        variables: { 'required' => ['name'], 'optional' => [] },
        syntax: :liquid
      )

      assert_not template.valid?
      assert_includes template.errors[:base].join, 'still has standard placeholders'
      assert_not_includes template.errors[:body].join, 'Must include the required variable'
    end

    test 'liquid save is blocked for html templates' do
      template = build(
        :email_template,
        :html,
        subject: 'Hello {{ name }}',
        body: '<p>Body {{ name }}</p>',
        variables: { 'required' => ['name'], 'optional' => [] },
        syntax: :liquid
      )

      assert_not template.valid?
      assert_includes template.errors[:syntax].join, 'only available for text templates'

      error = assert_raises(ArgumentError) do
        template.render(name: 'Alex')
      end
      assert_includes error.message, 'only available for text templates'
    end

    test 'liquid does not fall back to percent interpolation' do
      template = build(
        :email_template,
        :text,
        subject: 'Hello %<name>s',
        body: 'Body {{ name }}',
        variables: { 'required' => ['name'], 'optional' => [] },
        syntax: :liquid
      )

      subject, body = template.render(name: 'Alex')

      assert_equal 'Hello %<name>s', subject
      assert_equal 'Body Alex', body
    end
  end
end
