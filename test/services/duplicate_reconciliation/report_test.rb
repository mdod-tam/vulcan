# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'tempfile'

module DuplicateReconciliation
  class ReportTest < ActiveSupport::TestCase
    test 'prints bounded facts without raw contact values or date of birth' do
      date_of_birth = Date.new(1979, 11, 3)
      first = create(
        :constituent,
        first_name: 'Private',
        last_name: 'Pair',
        date_of_birth: date_of_birth,
        email: 'private-first@example.com',
        phone: '410-555-0111'
      )
      second = create(
        :constituent,
        first_name: 'PRIVATE',
        last_name: 'PAIR',
        date_of_birth: date_of_birth,
        email: 'private-second@example.com',
        phone: '410-555-0222'
      )
      create(:application, :approved, user: second)
      output = StringIO.new

      result = nil
      assert_no_difference ['DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
        result = Report.new.call(output: output)
      end

      assert_includes result.pairs.map(&:ids), [first.id, second.id].sort
      assert_includes output.string, "##{first.id} Private Pair"
      assert_includes output.string, 'email present: yes'
      assert_includes output.string, 'phone present: yes'
      assert_includes output.string, 'applications: approved-only'
      assert_no_raw_private_values(output.string, date_of_birth)
    end

    test 'writes optional CSV with the same privacy boundary' do
      date_of_birth = Date.new(1988, 2, 14)
      first = create_match(date_of_birth:, email: 'csv-first@example.com', phone: '410-555-0333')
      second = create_match(date_of_birth:, email: 'csv-second@example.com', phone: '410-555-0444')

      Tempfile.create(['duplicate-report', '.csv']) do |file|
        Report.new.call(output: StringIO.new, csv_path: file.path)
        csv = File.read(file.path)

        assert_includes csv, "#{[first.id, second.id].sort.join('-')},unreviewed"
        assert_includes csv, 'first_user_email_present'
        assert_no_raw_private_values(csv, date_of_birth)
      end
    end

    private

    def create_match(date_of_birth:, email:, phone:)
      create(
        :constituent,
        first_name: 'CSV',
        last_name: 'Privacy',
        date_of_birth: date_of_birth,
        email: email,
        phone: phone
      )
    end

    def assert_no_raw_private_values(text, date_of_birth)
      assert_not_includes text, 'private-first@example.com'
      assert_not_includes text, 'private-second@example.com'
      assert_not_includes text, 'csv-first@example.com'
      assert_not_includes text, 'csv-second@example.com'
      assert_not_includes text, '410-555-0111'
      assert_not_includes text, '410-555-0222'
      assert_not_includes text, '410-555-0333'
      assert_not_includes text, '410-555-0444'
      assert_not_includes text, date_of_birth.iso8601
      assert_not_includes text, date_of_birth.strftime('%m/%d/%Y')
    end
  end
end
