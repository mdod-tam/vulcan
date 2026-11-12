# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationNotesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      @application = create(:application, user: create(:constituent, email: "constituent#{@admin.email}"))
      sign_in_as(@admin, bypass_mfa_enrollment: true)
    end

    test 'should create internal note' do
      assert_difference('ApplicationNote.count') do
        post admin_application_notes_path(@application), params: {
          application_note: {
            content: 'This is an internal note',
            internal_only: true
          }
        }
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Note added successfully.', flash[:notice]

      note = ApplicationNote.last
      assert_equal @application, note.application
      assert_equal @admin, note.admin
      assert_equal 'This is an internal note', note.content
      assert note.internal_only
    end

    test 'should create public note' do
      assert_difference('ApplicationNote.count') do
        post admin_application_notes_path(@application), params: {
          application_note: {
            content: 'This is a public note',
            internal_only: false
          }
        }
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Note added successfully.', flash[:notice]

      note = ApplicationNote.last
      assert_equal @application, note.application
      assert_equal @admin, note.admin
      assert_equal 'This is a public note', note.content
      assert_not note.internal_only
    end

    test 'should not create note with empty content' do
      assert_no_difference('ApplicationNote.count') do
        post admin_application_notes_path(@application), params: {
          application_note: {
            content: '',
            internal_only: true
          }
        }
      end

      assert_redirected_to admin_application_path(@application)
      assert_match(/Failed to add note/, flash[:alert])
    end

    test 'the admin can assign complete reopen and unassign an existing note with attributed history' do
      note = create(:application_note, application: @application, admin: @admin)
      assignee = create(:admin)
      actions = [
        [{ assigned_to_id: assignee.id }, 'note_assigned', "Note assigned to #{assignee.full_name}."],
        [{ mark_done: true }, 'note_completed', 'Note marked as done.'],
        [{ mark_incomplete: true }, 'note_reopened', 'Note reopened.'],
        [{ unassign: true }, 'note_unassigned', 'Note unassigned successfully.']
      ]
      actions.each do |params, action, notice|
        assert_difference -> { @application.events.where(action: action).count }, 1 do
          patch admin_application_note_path(@application, note), params: params
        end
        assert_redirected_to admin_application_path(@application)
        assert_equal notice, flash[:notice]
        note.reload
        if params[:unassign]
          assert_nil note.assigned_to_id, 'Unassign must clear the assignee'
        else
          assert_equal assignee.id, note.assigned_to_id, "#{action} must retain the selected assignee"
        end
        params[:mark_done] ? assert_not_nil(note.completed_at) : assert_nil(note.completed_at)
        event = @application.events.find_by!(action: action)
        assert_equal [@admin.id, note.id], [event.user_id, event.metadata['note_id']]
      end
      assert_equal 'This is a note about the application.', note.content
    end

    test 'a note from another application and a request without an action leave note state unchanged' do
      note = create(:application_note, application: @application, admin: @admin)
      other_application = create(:application)
      foreign_note = create(:application_note, application: other_application, admin: @admin)
      original = [note.attributes, foreign_note.attributes]

      assert_no_difference('Event.count') do
        patch admin_application_note_path(@application, foreign_note), params: { mark_done: true }
      end
      assert_response :not_found
      assert_equal original, [note.reload.attributes, foreign_note.reload.attributes]

      assert_no_difference('Event.count') do
        patch admin_application_note_path(@application, note)
      end
      assert_redirected_to admin_application_path(@application)
      assert_equal 'No action provided.', flash[:alert]
      assert_equal original, [note.reload.attributes, foreign_note.reload.attributes]
    end

    test 'should create note with assignment' do
      other_admin = create(:admin)
      assert_difference('ApplicationNote.count') do
        post admin_application_notes_path(@application), params: {
          application_note: {
            content: 'This is an assigned note',
            internal_only: true,
            assigned_to_id: other_admin.id
          }
        }
      end

      assert_redirected_to admin_application_path(@application)
      note = ApplicationNote.last
      assert_equal other_admin.id, note.assigned_to_id
    end
  end
end
