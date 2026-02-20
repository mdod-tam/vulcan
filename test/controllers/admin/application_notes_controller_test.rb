# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationNotesControllerTest < ActionDispatch::IntegrationTest
    # AuthenticationTestHelper is included globally via test_helper

    setup do
      @admin = create(:admin) # Use the dedicated :admin factory
      @application = create(:application, user: create(:constituent, email: "constituent#{@admin.email}"))
      sign_in_as(@admin) # Use the standard helper for authentication
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

    # Authentication is skipped in test environment in Admin::BaseController
    # So we can't test authentication requirements directly
    test 'should set current user from authentication' do
      # Verify that the current_user is set correctly
      post admin_application_notes_path(@application), params: {
        application_note: {
          content: 'Test note with authentication',
          internal_only: true
        }
      }

      assert_redirected_to admin_application_path(@application)

      note = ApplicationNote.last
      assert_equal @admin.id, note.admin_id, 'Note should be created with the authenticated admin user'
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
