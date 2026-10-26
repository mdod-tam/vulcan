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
      history = css_select('h2').find { |heading| heading.text == 'Recent Changes' }.parent.parent.text
      assert_match 'Sam Staff', history
      assert_match 'Gail Guardian', history
      assert_no_match 'Towson', history
      assert_no_match 'Bel Air', history
      assert_match 'Date of birth', history
      # The same field history remains visible without disclosing date or location values.
      assert_no_match '2012-05-15', history
      assert_no_match '2012-05-16', history
      assert_includes history, '[withheld]'
      dob_event = Event.where(action: 'profile_updated_by_guardian').where("metadata->>'user_id' = ?", @dependent.id.to_s).last
      assert_equal({ 'old' => '[withheld]', 'new' => '[withheld]' }, dob_event.metadata['changes']['date_of_birth'])
      assert_nil dob_event.change_values
    end

    def with_actor(user)
      Current.user = user
      yield
    ensure
      Current.reset
    end
  end
end
