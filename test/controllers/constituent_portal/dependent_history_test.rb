# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  # Both dependent pages render the recent-changes history from profile-change audit events.
  class DependentHistoryTest < ActionDispatch::IntegrationTest
    setup do
      @guardian = create(:constituent, first_name: 'Gail', last_name: 'Guardian')
      @dependent = create(:constituent, first_name: 'Dee', last_name: 'Pendent', city: 'Baltimore',
                                        date_of_birth: Date.new(2012, 5, 15))
      GuardianRelationship.create!(guardian_id: @guardian.id, dependent_id: @dependent.id, relationship_type: 'Parent')
      @admin = create(:admin, first_name: 'Sam', last_name: 'Staff')

      with_actor(@guardian) { @dependent.update!(city: 'Towson', date_of_birth: '05/16/2012') }
      with_actor(@admin) { @dependent.update!(city: 'Bel Air') }

      sign_in_for_integration_test(@guardian)
    end

    test 'the details page lists guardian and staff changes' do
      get constituent_portal_dependent_path(@dependent)

      assert_response :success
      assert_history
    end

    test 'the edit page lists guardian and staff changes' do
      get edit_constituent_portal_dependent_path(@dependent)

      assert_response :success
      assert_history
    end

    test 'a staff edit is recorded as an admin change, not a guardian change' do
      actions = Event.where("metadata->>'user_id' = ?", @dependent.id.to_s).order(:id).pluck(:action)

      assert_equal %w[profile_updated_by_guardian profile_updated_by_admin], actions.last(2)
    end

    private

    def assert_history
      assert_match 'Sam Staff', response.body
      assert_match 'Gail Guardian', response.body
      assert_match 'Towson', response.body
      assert_match 'Bel Air', response.body
      assert_match 'Date of birth', response.body
      # Decrypted from Event#change_values for display; the event's plain metadata holds no value.
      assert_match '2012-05-15', response.body
      assert_match '2012-05-16', response.body
      dob_event = Event.where(action: 'profile_updated_by_guardian').where("metadata->>'user_id' = ?", @dependent.id.to_s).last
      assert_equal({}, dob_event.metadata['changes']['date_of_birth'])
    end

    def with_actor(user)
      Current.user = user
      yield
    ensure
      Current.reset
    end
  end
end
