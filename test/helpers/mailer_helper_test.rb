# frozen_string_literal: true

require 'test_helper'

class MailerHelperTest < ActionView::TestCase
  include MailerHelper

  test 'format_date handles nil value' do
    assert_equal '', format_date(nil)
  end

  test 'format_date handles Date objects' do
    date = Date.new(2025, 3, 10)
    assert_equal 'March 10 2025', format_date(date)
    assert_equal '03/10/2025', format_date(date, :short)
    assert_equal 'March 10 2025', format_date(date, :long)
    assert_equal 'March 10 2025 at 12:00 AM', format_date(date, :full)
  end

  test 'format_date handles Time objects' do
    time = Time.zone.local(2025, 3, 10, 15, 30, 0)
    assert_equal 'March 10 2025', format_date(time)
    assert_equal '03/10/2025', format_date(time, :short)
    assert_equal 'March 10 2025 at 03:30 PM', format_date(time, :full)
  end

  test 'format_date handles string dates without time components' do
    # Valid string date without time
    assert_equal 'March 10 2025', format_date('2025-03-10')
    assert_equal '03/10/2025', format_date('2025-03-10', :short)
    assert_equal 'March 10 2025 at 12:00 AM', format_date('2025-03-10', :full)
  end

  test 'format_date handles string dates with time components' do
    # Valid datetime string with time
    assert_equal 'March 10 2025', format_date('2025-03-10 15:30:00')
    assert_equal '03/10/2025', format_date('2025-03-10 15:30:00', :short)

    # With our fixed implementation, time components should be preserved when using :full format
    assert_equal 'March 10 2025 at 03:30 PM', format_date('2025-03-10 15:30:00', :full)

    # Test with different time formats
    assert_equal 'March 10 2025 at 03:30 PM', format_date('2025-03-10T15:30:00', :full)
    assert_equal 'March 10 2025 at 03:30 PM', format_date('2025-03-10 15:30', :full)
  end

  test 'format_date returns original string for invalid dates' do
    invalid_date = 'not-a-date'
    assert_equal invalid_date, format_date(invalid_date)
  end

  test 'format_date handles unexpected format parameter' do
    date = Date.new(2025, 3, 10)
    assert_equal 'March 10 2025', format_date(date, :unknown_format)
  end

  test 'format_date retains its fallback without logging the date or exception text' do
    date = Date.new(2025, 3, 10)
    date.stubs(:strftime).raises(ArgumentError, 'private-date-value')
    date.expects(:inspect).never
    Rails.logger.expects(:error).with('Error formatting date: ArgumentError').once

    assert_equal '2025-03-10', format_date(date)
  end
end
