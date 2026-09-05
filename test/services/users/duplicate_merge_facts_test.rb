# frozen_string_literal: true

require 'test_helper'

module Users
  class DuplicateMergeFactsTest < ActiveSupport::TestCase
    test 'compares the bounded merge facts and normalizes blank strings' do
      first = build(
        :constituent,
        date_of_birth: Date.new(1980, 1, 15),
        phone: '410-555-0101',
        phone_type: 'voice',
        physical_address_2: nil,
        communication_preference: :email
      )
      second = build(
        :constituent,
        date_of_birth: Date.new(1980, 1, 15),
        phone: '410-555-0101',
        phone_type: 'voice',
        physical_address_2: ' ',
        communication_preference: :email
      )

      facts = DuplicateMergeFacts.new(first, second)

      DuplicateMergeFacts::FACTS.each { |fact| assert facts.agreed?(fact), "expected #{fact} to agree" }
      assert_equal '410-555-0101', facts.agreed_value(:phone)
    end

    test 'keeps each independently differing fact separate' do
      first = build(:constituent, date_of_birth: Date.new(1980, 1, 15), phone: '410-555-0101')
      second = build(
        :constituent,
        date_of_birth: Date.new(1981, 1, 15),
        phone: '410-555-0102',
        phone_type: 'text',
        physical_address_1: 'Different address',
        communication_preference: :letter
      )

      facts = DuplicateMergeFacts.new(first, second)

      DuplicateMergeFacts::FACTS.each { |fact| assert_not facts.agreed?(fact), "expected #{fact} to differ" }
    end

    test 'rejects unsupported fact names' do
      facts = DuplicateMergeFacts.new(build(:constituent), build(:constituent))

      assert_raises(ArgumentError) { facts.agreed?(:email) }
    end
  end
end
