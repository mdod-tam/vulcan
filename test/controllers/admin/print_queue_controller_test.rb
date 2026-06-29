# frozen_string_literal: true

require 'test_helper'

module Admin
  class PrintQueueControllerTest < ActionDispatch::IntegrationTest
    # Add fixtures declaration to fix 'undefined method users' error
    # fixtures :users, :print_queue_items

    def setup
      # Use factories instead of fixtures
      @admin = create(:admin, email: 'admin_test@example.com')

      # Create test PDF file
      test_pdf = fixture_file_upload('test.pdf', 'application/pdf')

      # Create constituent
      constituent = create(:constituent)

      # Create print queue items with attached PDFs and use the created constituent
      # Override the factory defaults to use our pre-created users
      @pending_letter = build(:print_queue_item,
                              status: :pending,
                              constituent: constituent,
                              application: create(:application, user: constituent),
                              admin: nil)
      @pending_letter.pdf_letter.attach(io: test_pdf.open, filename: 'test_letter.pdf')
      @pending_letter.save!

      @pending_letter2 = build(:print_queue_item,
                               status: :pending,
                               constituent: constituent,
                               application: create(:application, user: constituent),
                               admin: nil)
      @pending_letter2.pdf_letter.attach(io: test_pdf.open, filename: 'test_letter2.pdf')
      @pending_letter2.save!

      @printed_letter = build(:print_queue_item,
                              status: :printed,
                              constituent: constituent,
                              application: create(:application, user: constituent),
                              admin: @admin,
                              printed_at: 1.day.ago)
      @printed_letter.pdf_letter.attach(io: test_pdf.open, filename: 'printed_letter.pdf')
      @printed_letter.save!

      @headers = {
        'HTTP_USER_AGENT' => 'Rails Testing',
        'REMOTE_ADDR' => '127.0.0.1'
      }

      # Sign in as admin using the proper integration test helper
      sign_in_for_integration_test(@admin)

      # Since there's no redirect to follow, we manually navigate to a page
      # to ensure authentication is active
      get admin_print_queue_index_path
    end

    def test_should_get_index
      get admin_print_queue_index_path
      assert_response :success
      assert_select 'h1', text: 'Print Queue'
      assert_select '.letter-checkbox', { minimum: 2 } # At least 2 checkboxes for pending letters
    end

    def test_should_show_letter_pdf
      get admin_print_queue_path(@pending_letter, format: :pdf)
      assert_response :success
      assert_equal 'application/pdf', response.content_type
      assert_match(/^inline/, response.headers['Content-Disposition'])
      assert_includes response.headers['Content-Disposition'], @pending_letter.pdf_filename
    end

    def test_should_download_single_letter
      get download_batch_admin_print_queue_index_path, params: { letter_ids: [@pending_letter.id] }
      assert_response :success
      assert_equal 'application/pdf', response.content_type
      assert_match(/attachment/, response.headers['Content-Disposition'])
      assert_includes response.headers['Content-Disposition'], @pending_letter.pdf_filename
    end

    def test_should_download_multiple_letters_as_zip
      # Make sure the letters have PDF files attached before testing
      assert @pending_letter.pdf_letter.attached?
      assert @pending_letter2.pdf_letter.attached?

      # Manually skip this test if the attachments don't exist yet (for CI environments)
      skip 'Test attachments not properly set up' if !@pending_letter.pdf_letter.attached? || !@pending_letter2.pdf_letter.attached?

      # Mock the zip file creation to avoid issues in test environment
      mock_zipfile = Tempfile.new('test.zip')
      mock_zipfile.write('mock zip content')
      mock_zipfile.rewind

      Tempfile.stub :new, mock_zipfile do
        File.stub :exist?, true do
          get download_batch_admin_print_queue_index_path,
              params: { letter_ids: [@pending_letter.id, @pending_letter2.id] }
          assert_response :success
          assert_equal 'application/zip', response.content_type
          assert_match(/attachment/, response.headers['Content-Disposition'])
        end
      end

      mock_zipfile.close
      mock_zipfile.unlink
    end

    def test_should_redirect_if_no_letters_selected_for_download
      get download_batch_admin_print_queue_index_path, params: { letter_ids: [] }
      assert_redirected_to admin_print_queue_index_path
      assert_equal 'No letters selected for download', flash[:alert]
    end

    def test_should_mark_single_letter_as_printed
      post mark_as_printed_admin_print_queue_path(@pending_letter)
      assert_redirected_to admin_print_queue_index_path
      assert_equal 'Letter marked as printed', flash[:notice]

      # Verify the letter was marked as printed
      @pending_letter.reload
      assert_equal 'printed', @pending_letter.status
      assert_equal @admin.id, @pending_letter.admin_id
      assert_not_nil @pending_letter.printed_at
    end

    def test_should_mark_batch_as_printed
      assert_changes -> { PrintQueueItem.pending.count }, from: 2, to: 0 do
        post mark_batch_as_printed_admin_print_queue_index_path, params: {
          letter_ids: [@pending_letter.id, @pending_letter2.id]
        }
      end

      assert_redirected_to admin_print_queue_index_path
      assert_equal '2 letters marked as printed', flash[:notice]

      # Verify both letters are marked as printed
      @pending_letter.reload
      @pending_letter2.reload
      assert_equal 'printed', @pending_letter.status
      assert_equal 'printed', @pending_letter2.status
      assert_equal @admin.id, @pending_letter.admin_id
      assert_equal @admin.id, @pending_letter2.admin_id
    end

    def test_should_handle_empty_batch_for_mark_as_printed
      post mark_batch_as_printed_admin_print_queue_index_path, params: { letter_ids: [] }
      assert_redirected_to admin_print_queue_index_path
      assert_equal '0 letters marked as printed', flash[:notice]
    end
  end
end
