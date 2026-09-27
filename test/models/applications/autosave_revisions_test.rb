# frozen_string_literal: true

require 'test_helper'

module Applications
  class AutosaveRevisionsTest < ActiveSupport::TestCase
    setup do
      @actor = create(:constituent)
      @draft = create(:application, :draft, user: @actor, household_size: 2)
      @context = AutosaveRevisions.new(@draft).form_state[:context]
    end

    test 'malformed page ids and revisions cannot autosave or change ordering state' do
      [nil, '', 'not-a-page', {}, 'x' * 2049].each do |context|
        assert_revision_rejected(context: context, revision: 1)
      end
      [nil, '', 0, -1, 1.5, '1x', ' 1', '1 ', true, {}, AutosaveRevisions::MAX_REVISION + 1].each do |revision|
        assert_revision_rejected(revision: revision)
      end
    end

    test 'an old page still saves and its original ordering state is retained' do
      assert_equal :saved, apply_revision(revision: 2, value: 7)
      travel 25.hours do
        assert_equal :superseded, apply_revision(revision: 1, value: 4)
        assert_equal :saved, apply_revision(revision: 3, value: 8)
      end
      assert_equal 8, @draft.reload.household_size
    end

    test 'a full form advances its boundary even when its revision is older' do
      assert_equal :saved, apply_revision(revision: 5, value: 4)
      assert_equal :saved, apply_revision(revision: 3, field: nil, value: 7)
      assert_equal :superseded, apply_revision(revision: 5, value: 4)
      assert_equal 7, @draft.reload.household_size
      assert_equal :saved, apply_revision(revision: 6, value: 8)
    end

    test 'a full form with missing or malformed bookkeeping skips ordering' do
      [[nil, nil], ['bad-context', 1], [@context, 'bad-revision']].each do |context, revision|
        assert_equal :unversioned, apply_revision(context: context, revision: revision, field: nil, value: 7)
        assert_equal 7, @draft.reload.household_size
        assert_empty @draft.autosave_revisions
      end
    end

    test 'a first full form establishes its zero revision boundary' do
      assert_equal :saved, apply_revision(revision: 0, field: nil, value: 5)
      assert_equal 0, @draft.reload.autosave_revisions.fetch(@context).fetch('through')
      assert_equal :saved, apply_revision(revision: 1, value: 6)
    end

    test 'duplicates and older fields leave the complete persisted draft unchanged' do
      assert_equal :saved, apply_revision(revision: AutosaveRevisions::MAX_REVISION, value: 7)
      before = @draft.reload.attributes
      [AutosaveRevisions::MAX_REVISION, 2, 1].each do |revision|
        assert_equal :superseded, apply_revision(revision: revision, value: 4)
        assert_equal before, @draft.reload.attributes
      end
    end

    test 'independent pages remain last write wins without retiring old pages' do
      assert_equal :saved, apply_revision(revision: 10, value: 4)
      33.times { assert_equal :saved, apply_revision(context: SecureRandom.uuid, revision: 1, value: 7) }
      assert_equal :superseded, apply_revision(revision: 9, value: 4)
      assert_equal 7, @draft.reload.household_size
      assert_equal :saved, apply_revision(revision: 11, value: 8)
      assert_equal 8, @draft.reload.household_size
    end

    test 'rendered retries advance past submitted fields and full form revisions' do
      assert_equal 0, AutosaveRevisions.new(@draft).form_state[:revision]
      assert_equal :saved, apply_revision(revision: 3, value: 7)
      assert_equal({ context: @context, revision: 4 }, AutosaveRevisions.new(@draft).form_state(context: @context, revision: 1))
      assert_equal :saved, apply_revision(revision: 5, field: nil, value: 8)
      assert_equal({ context: @context, revision: 6 }, AutosaveRevisions.new(@draft).form_state(context: @context, revision: 5))
      state = AutosaveRevisions.new(@draft).form_state(context: 'bad-context', revision: 'bad-revision')
      assert_match AutosaveRevisions::PAGE_ID, state[:context]
      assert_equal 0, state[:revision]
    end

    private

    def apply_revision(revision:, context: @context, field: 'household_size', value: 9)
      @draft.with_lock do
        outcome = AutosaveRevisions.new(@draft).prepare!(context: context, revision: revision, field: field)
        unless outcome == :superseded
          @draft.household_size = value
          @draft.save!(validate: false)
        end
        outcome
      end
    end

    def assert_revision_rejected(**request)
      before = @draft.reload.attributes
      assert_raises(AutosaveRevisions::InvalidRevision) { apply_revision(**request) }
      assert_equal before, @draft.reload.attributes
    end
  end
end
