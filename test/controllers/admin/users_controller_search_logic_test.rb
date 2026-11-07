# frozen_string_literal: true

require 'test_helper'

module Admin
  class UsersControllerSearchLogicTest < ActiveSupport::TestCase
    test 'users_for_paper_search only returns constituent-compatible applicants' do
      controller = Admin::UsersController.new
      constituent = create(:constituent, email: generate(:email), first_name: 'LogicSearchUser')
      evaluator = create(:evaluator, email: generate(:email), first_name: 'LogicSearchUser', hearing_disability: true)
      create(:application, :archived, user: evaluator)

      results = controller.send(:users_for_paper_search, 'LogicSearchUser', 'constituent', limit: 10)

      assert_includes results.map(&:id), constituent.id
      assert_not_includes results.map(&:id), evaluator.id
    end

    test 'each role searches its own candidate rule' do
      suspended = create(:constituent, status: :suspended, last_name: 'StandingProbe')
      inactive = create(:constituent, status: :inactive, last_name: 'StandingProbe')
      active = create(:constituent, status: :active, last_name: 'StandingProbe')

      assert_equal [active.id, inactive.id, suspended.id].sort, search('StandingProbe', 'constituent').map(&:id).sort,
                   'an applicant may be suspended or inactive'
      assert_equal [active.id], search('StandingProbe', 'guardian').map(&:id), 'a guardian must be active'
    end

    test 'an ineligible full-name match does not hide eligible partial matches' do
      canonical = create(:constituent, last_name: 'Canonical')
      create(:constituent, first_name: 'Quenby', last_name: 'Valdrith', merged_into_user: canonical)
      same_first = create(:constituent, first_name: 'Quenby', last_name: 'Orsolay')
      same_last = create(:constituent, first_name: 'Tavish', last_name: 'Valdrith')

      assert_equal [same_first.id, same_last.id].sort, search('Quenby Valdrith', 'constituent').map(&:id).sort
    end

    test 'a role the paper forms do not send finds nothing, whoever matches the query' do
      constituent = create(:constituent, last_name: 'RoleProbe')
      create(:admin, last_name: 'RoleProbe')
      create(:constituent, last_name: 'RoleProbe', merged_into_user: constituent)

      assert_equal [constituent.id], search('RoleProbe', 'constituent').map(&:id)
      ['dependent', 'administrator', 'evaluator', '', nil].each do |role|
        assert_empty search('RoleProbe', role), "role #{role.inspect} must not search"
      end
    end

    private

    def search(query, role)
      Admin::UsersController.new.send(:users_for_paper_search, query, role, limit: 10)
    end
  end
end
