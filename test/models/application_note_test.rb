# frozen_string_literal: true

require 'test_helper'

class ApplicationNoteTest < ActiveSupport::TestCase
  setup do
    @application = create(:application)
    @admin = create(:admin)
  end

  test 'should create a valid application note' do
    note = ApplicationNote.new(
      application: @application,
      admin: @admin,
      content: 'This is a test note',
      internal_only: true
    )
    assert note.valid?
  end

  test 'should require content' do
    note = ApplicationNote.new(
      application: @application,
      admin: @admin,
      internal_only: true
    )
    assert_not note.valid?
    assert_includes note.errors[:content], "can't be blank"
  end

  test 'should require application' do
    note = ApplicationNote.new(
      admin: @admin,
      content: 'This is a test note',
      internal_only: true
    )
    assert_not note.valid?
    assert_includes note.errors[:application], 'must exist'
  end

  test 'should require admin' do
    note = ApplicationNote.new(
      application: @application,
      content: 'This is a test note',
      internal_only: true
    )
    assert_not note.valid?
    assert_includes note.errors[:admin], 'must exist'
  end

  test 'public_notes scope should return only public notes' do
    create(:application_note, :internal, application: @application)
    public_note = create(:application_note, :public, application: @application)

    assert_equal 1, @application.application_notes.public_notes.count
    assert_equal public_note.id, @application.application_notes.public_notes.first.id
  end

  test 'internal_notes scope should return only internal notes' do
    internal_note = create(:application_note, :internal, application: @application)
    create(:application_note, :public, application: @application)

    assert_equal 1, @application.application_notes.internal_notes.count
    assert_equal internal_note.id, @application.application_notes.internal_notes.first.id
  end

  test 'recent_first scope should order notes by created_at desc' do
    older_note = create(:application_note, application: @application, created_at: 2.days.ago)
    newer_note = create(:application_note, application: @application, created_at: 1.day.ago)

    notes = @application.application_notes.recent_first
    assert_equal newer_note.id, notes.first.id
    assert_equal older_note.id, notes.last.id
  end

  test 'assigned scope should return only assigned notes' do
    assigned_note = create(:application_note, application: @application, assigned_to: @admin)
    create(:application_note, application: @application)

    assert_equal 1, @application.application_notes.assigned.count
    assert_equal assigned_note.id, @application.application_notes.assigned.first.id
  end

  test 'unassigned scope should return only unassigned notes' do
    create(:application_note, application: @application, assigned_to: @admin)
    unassigned_note = create(:application_note, application: @application)

    assert_equal 1, @application.application_notes.unassigned.count
    assert_equal unassigned_note.id, @application.application_notes.unassigned.first.id
  end

  test 'assigned_to scope should return notes assigned to specific user' do
    other_admin = create(:admin)
    create(:application_note, application: @application, assigned_to: @admin)
    note_for_other = create(:application_note, application: @application, assigned_to: other_admin)

    assert_equal 1, @application.application_notes.assigned_to(other_admin).count
    assert_equal note_for_other.id, @application.application_notes.assigned_to(other_admin).first.id
  end

  test 'assign_to! should assign note to user and log audit event' do
    note = create(:application_note, application: @application)
    other_admin = create(:admin)

    assert_nil note.assigned_to_id
    assert note.assign_to!(other_admin)
    assert_equal other_admin.id, note.reload.assigned_to_id
  end

  test 'unassign! should remove assignment and log audit event' do
    note = create(:application_note, application: @application, assigned_to: @admin)

    assert_equal @admin.id, note.assigned_to_id
    assert note.unassign!
    assert_nil note.reload.assigned_to_id
  end

  test 'incomplete scope should return only incomplete notes' do
    incomplete_note = create(:application_note, application: @application)
    create(:application_note, application: @application, completed_at: Time.current)

    assert_equal 1, @application.application_notes.incomplete.count
    assert_equal incomplete_note.id, @application.application_notes.incomplete.first.id
  end

  test 'completed scope should return only completed notes' do
    create(:application_note, application: @application)
    completed_note = create(:application_note, application: @application, completed_at: Time.current)

    assert_equal 1, @application.application_notes.completed.count
    assert_equal completed_note.id, @application.application_notes.completed.first.id
  end

  test 'mark_as_done! should set completed_at and log audit event' do
    note = create(:application_note, application: @application, assigned_to: @admin)

    assert_nil note.completed_at
    assert note.mark_as_done!
    assert_not_nil note.reload.completed_at
  end

  test 'mark_as_incomplete! should clear completed_at and log audit event' do
    note = create(:application_note, application: @application, assigned_to: @admin, completed_at: Time.current)

    assert_not_nil note.completed_at
    assert note.mark_as_incomplete!
    assert_nil note.reload.completed_at
  end
end
