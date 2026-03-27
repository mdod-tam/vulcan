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

    test 'users_for_paper_search keeps legacy Constituent STI rows' do
      controller = Admin::UsersController.new
      legacy = create(:constituent, email: generate(:email), first_name: 'LegacyLogicSearchUser')
      legacy.update_column(:type, 'Constituent')

      results = controller.send(:users_for_paper_search, 'LegacyLogicSearchUser', 'constituent', limit: 10)

      assert_includes results.map(&:id), legacy.id
    end
  end
end
