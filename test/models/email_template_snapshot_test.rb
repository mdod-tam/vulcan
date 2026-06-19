# frozen_string_literal: true

require 'test_helper'

class EmailTemplateSnapshotTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @template = create(:email_template, :text,
                       subject: 'Original subject',
                       body: 'Original body %<name>s',
                       description: 'Original description',
                       enabled: true)
    @before_attributes = @template.snapshot_content_attributes
  end

  test 'record! stores full render-relevant snapshot after admin edit' do
    @template.update!(subject: 'Updated subject', body: 'Updated body %<name>s')

    snapshot = EmailTemplateSnapshot.record!(
      template: @template,
      change_source: 'admin_edit',
      actor: @admin
    )

    assert_equal 1, snapshot.snapshot_number
    assert_equal 'Updated subject', snapshot.subject
  end

  test 'first record! with before_attributes stores baseline then post-edit snapshot' do
    @template.update!(subject: 'Updated subject', body: 'Updated body %<name>s')

    assert_difference -> { @template.email_template_snapshots.count }, +2 do
      EmailTemplateSnapshot.record!(
        template: @template,
        change_source: 'admin_edit',
        actor: @admin,
        before_attributes: @before_attributes
      )
    end

    prior = @template.prior_snapshot

    assert_equal 'baseline', prior.change_source
    assert_equal 'Original subject', prior.subject
    assert_equal 'Original body %<name>s', prior.body
    assert_equal 'Updated subject', @template.email_template_snapshots.ordered.first.subject
  end

  test 'record! increments snapshot_number per template' do
    EmailTemplateSnapshot.record!(template: @template, change_source: 'admin_edit', actor: @admin)
    @template.update!(body: 'Second body %<name>s')
    second = EmailTemplateSnapshot.record!(template: @template, change_source: 'admin_edit', actor: @admin)

    assert_equal 2, second.snapshot_number
  end

  test 'rejects invalid change_source' do
    assert_raises(ArgumentError) do
      EmailTemplateSnapshot.record!(template: @template, change_source: 'invalid', actor: @admin)
    end
  end

  test 'render_relevant_change_between? compares before and after state' do
    @template.update!(subject: 'Changed')

    assert EmailTemplateSnapshot.render_relevant_change_between?(@before_attributes, @template)

    unchanged = @before_attributes.merge(subject: 'Changed')
    assert_not EmailTemplateSnapshot.render_relevant_change_between?(unchanged, @template)
  end

  test 'prior_snapshot returns second most recent snapshot' do
    @template.update!(body: 'First edit %<name>s')
    EmailTemplateSnapshot.record!(
      template: @template,
      change_source: 'admin_edit',
      actor: @admin,
      before_attributes: @before_attributes
    )
    before_second_edit = @template.snapshot_content_attributes
    @template.update!(body: 'Second edit %<name>s')
    EmailTemplateSnapshot.record!(
      template: @template,
      change_source: 'admin_edit',
      actor: @admin,
      before_attributes: before_second_edit
    )

    prior = @template.prior_snapshot

    assert_not_nil prior
    assert_equal 'First edit %<name>s', prior.body
    assert_equal 2, prior.snapshot_number
  end

  test 'legacy_previous_version? remains when prior_snapshot is nil' do
    @template.update!(previous_subject: 'Old subject', previous_body: 'Old body')
    @template.update_column(:version, 2) # rubocop:disable Rails/SkipsModelValidations

    assert @template.legacy_previous_version?

    EmailTemplateSnapshot.record!(template: @template, change_source: 'admin_edit', actor: @admin)

    assert_nil @template.prior_snapshot
    assert @template.legacy_previous_version?
  end
end
