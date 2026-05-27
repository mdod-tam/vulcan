# frozen_string_literal: true

require 'test_helper'

module Users
  class FilterServiceTest < ActiveSupport::TestCase
    test 'searches by first name last name and full name' do
      matching_user = create(:constituent, first_name: 'Ada', last_name: 'Lovelace')
      other_user = create(:constituent, first_name: 'Grace', last_name: 'Hopper')
      scope = User.where(id: [matching_user.id, other_user.id])

      assert_filter_matches scope, 'Ada', matching_user, other_user
      assert_filter_matches scope, 'Lovelace', matching_user, other_user
      assert_filter_matches scope, 'Ada Lovelace', matching_user, other_user
    end

    test 'searches by email tokens' do
      matching_user = create(:constituent, email: 'alex.smith+portal@searchable-domain.test')
      other_user = create(:constituent, email: 'unmatched.person@example.com')
      scope = User.where(id: [matching_user.id, other_user.id])

      assert_filter_matches scope, 'alex.smith+portal@searchable-domain.test', matching_user, other_user
      assert_filter_matches scope, 'alex.smith+portal@', matching_user, other_user
      assert_filter_matches scope, 'alex.smith+portal@search', matching_user, other_user
      assert_filter_matches scope, 'alex', matching_user, other_user
      assert_filter_matches scope, 'smit', matching_user, other_user
      assert_filter_matches scope, 'portal', matching_user, other_user
      assert_filter_matches scope, 'searchable-domain.test', matching_user, other_user
      assert_filter_matches scope, 'search', matching_user, other_user
    end

    test 'searches underscore email tokens literally' do
      matching_user = create(:constituent, email: 'firstname_lastname@member.senate.gov')
      other_user = create(:constituent, email: 'firstnameXlastname@member.senate.gov')
      scope = User.where(id: [matching_user.id, other_user.id])

      assert_filter_matches scope, 'firstname_lastname', matching_user, other_user
      assert_filter_matches scope, 'firstname_lastname@member.senate.gov', matching_user, other_user
    end

    test 'searches by dependent email and guardian fallback email' do
      dependent_with_email = create(:constituent, email: 'system.dependent@example.com',
                                                  dependent_email: 'child.contact@example.com')
      guardian = create(:constituent, email: 'guardian.fallback@example.com')
      fallback_dependent = create(:constituent, email: 'dependent.system@example.com', dependent_email: nil)
      other_user = create(:constituent, email: 'unmatched.guardian@example.com')
      create(:guardian_relationship, guardian_user: guardian, dependent_user: fallback_dependent,
                                     relationship_type: 'Parent')
      scope = User.where(id: [dependent_with_email.id, guardian.id, fallback_dependent.id, other_user.id])

      assert_filter_matches scope, 'contact', dependent_with_email, other_user

      result = FilterService.new(scope, { q: 'fallback' }).apply_filters

      assert result.success?
      assert_includes result.data, guardian
      assert_includes result.data, fallback_dependent
      assert_not_includes result.data, other_user
    end

    private

    def assert_filter_matches(scope, query, matching_user, other_user)
      result = FilterService.new(scope, { q: query }).apply_filters

      assert result.success?
      assert_includes result.data, matching_user
      assert_not_includes result.data, other_user
    end
  end
end
