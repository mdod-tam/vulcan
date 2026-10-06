# frozen_string_literal: true

require 'test_helper'

module Applications
  # Detection, receipts, and selection read identity_facts, where an unreadable date of birth would
  # be indistinguishable from none. The review refuses it before any of them run.
  class PaperIdentityReviewDateOfBirthTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @facts = { first_name: 'Dob', last_name: 'Review', date_of_birth: '9/9/26',
                 email: "dob-review-#{SecureRandom.hex(4)}@example.com", phone: '555-000-0456' }
    end

    test 'an unreadable date of birth stops the review with no candidates or receipt' do
      create(:constituent, first_name: 'Dob', last_name: 'Review', date_of_birth: Date.new(2009, 9, 26))

      result = review(@facts)

      assert result.invalid_input?
      assert_not result.permits_creation?
      assert_empty result.candidates
      assert_nil result.token
    end

    test 'an alternate spelling reviews the same as the canonical one' do
      existing = create(:constituent, first_name: 'Dob', last_name: 'Review', date_of_birth: Date.new(2009, 9, 26))

      %w[09/26/2009 09-26-2009 09262009].each do |spelling|
        result = review(@facts.merge(date_of_birth: spelling))

        assert result.needs_confirmation?, "#{spelling}: #{result.state}"
        assert_equal [existing.id], result.candidates.map(&:id)
      end
    end

    test 'a blank date of birth is not treated as invalid' do
      assert_not review(@facts.merge(date_of_birth: '')).invalid_input?
    end

    test 'detection facts carry the parsed date' do
      assert_equal Date.new(2026, 9, 9), PaperIdentityReview.detection_facts(date_of_birth: '09092026')[:date_of_birth]
      assert_nil PaperIdentityReview.detection_facts(date_of_birth: '9/9/26')[:date_of_birth]
    end

    private

    def review(facts)
      PaperIdentityReview.new(constituent_params: facts, admin: @admin).call
    end
  end
end
