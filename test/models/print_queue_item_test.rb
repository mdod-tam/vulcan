# frozen_string_literal: true

require 'test_helper'

class PrintQueueItemTest < ActiveSupport::TestCase
  # Set up test helpers
  def setup
    @constituent = create(:constituent)
    @admin = create(:admin)
    @application = create(:application, user: @constituent)

    # Create a new print queue item first
    @pending_letter = PrintQueueItem.new(
      letter_type: :registration_confirmation,
      status: :pending,
      constituent: @constituent,
      application: @application
    )

    # Create a mock attachment instead of using a real file
    # This prevents ActiveStorage errors in tests
    mock_pdf = mock_attached_file(
      filename: 'test_letter.pdf',
      content_type: 'application/pdf',
      byte_size: 10.kilobytes
    )

    # Stub the attachment methods
    @pending_letter.stubs(:pdf_letter).returns(mock_pdf)
    @pending_letter.stubs(:pdf_letter_attached?).returns(true)

    # Track execution time for performance monitoring
    @start_time = Time.current
  end

  teardown do
    # Log test execution time for performance monitoring
    if defined?(measure_time) && @start_time
      true
    end
  end

  test 'should be valid with required attributes' do
    assert @pending_letter.valid?
  end

  test 'should require letter_type' do
    @pending_letter.letter_type = nil
    assert_not @pending_letter.valid?
    assert_includes @pending_letter.errors.full_messages, "Letter type can't be blank"
  end

  test 'should require pdf_letter attachment on create' do
    # Create a new item without mocking the attachment
    letter = PrintQueueItem.new(
      letter_type: :registration_confirmation,
      status: :pending,
      constituent: @constituent,
      application: @application
    )

    # In a real scenario, no attachment would be present
    letter.stubs(:pdf_letter_attached?).returns(false)

    assert_not letter.valid?
    assert_includes letter.errors.full_messages, "Pdf letter can't be blank"
  end

  test 'should require constituent' do
    @pending_letter.constituent = nil
    assert_not @pending_letter.valid?
    assert_includes @pending_letter.errors.full_messages, 'Constituent must exist'
  end

  test 'application should be optional' do
    @pending_letter.application = nil
    assert @pending_letter.valid?
  end

  test 'should set default status to pending' do
    # Create a new letter with mocked attachment
    letter = PrintQueueItem.new(
      letter_type: :registration_confirmation,
      constituent: @constituent
    )

    # Mock the attachment
    mock_pdf = mock_attached_file(filename: 'test_letter.pdf')
    letter.stubs(:pdf_letter).returns(mock_pdf)
    letter.stubs(:pdf_letter_attached?).returns(true)

    # Use safe interaction pattern if available
    result = if respond_to?(:safe_interaction)
               safe_interaction { letter.save }
             else
               letter.save
             end

    assert result, "Failed to save the letter: #{letter.errors.full_messages.join(', ')}"
    assert_equal 'pending', letter.status
  end

  test 'should have scopes for filtering' do
    assert_respond_to PrintQueueItem, :pending
    assert_respond_to PrintQueueItem, :recent
  end

  test 'should mark as printed' do
    # Set up the letter for printing with mocked save
    @pending_letter.stubs(:save).returns(true)
    @pending_letter.id = 1 # Simulate an ID for the record

    # Verify the status change
    assert_changes -> { @pending_letter.status }, from: 'pending', to: 'printed' do
      if respond_to?(:safe_interaction)
        safe_interaction { @pending_letter.mark_as_printed(@admin) }
      else
        @pending_letter.mark_as_printed(@admin)
      end
    end

    assert_equal @admin.id, @pending_letter.admin_id
    assert_not_nil @pending_letter.printed_at
  end

  test 'pdf_filename uses letter type and constituent id' do
    assert_equal "registration_confirmation_#{@constituent.id}.pdf", @pending_letter.pdf_filename
  end

  # Helper method to set up mock attachments for all PrintQueueItems
  def setup_attachment_mocks_for_print_queue
    PrintQueueItem.find_each do |item|
      next if item.pdf_letter_attached? # Skip if already mocked

      mock_pdf = mock_attached_file(filename: "letter_#{item.id}.pdf")
      item.stubs(:pdf_letter).returns(mock_pdf)
      item.stubs(:pdf_letter_attached?).returns(true)
    end
  end
end
