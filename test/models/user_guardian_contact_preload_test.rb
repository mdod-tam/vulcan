# frozen_string_literal: true

require 'test_helper'

# Contact resolution must give the same answer whether the guardian associations were loaded ahead
# of time or are read lazily.
class UserGuardianContactPreloadTest < ActiveSupport::TestCase
  PRELOADS = [:guardians, { guardian_relationships_as_dependent: :guardian_user, guardian_relationships_as_guardian: :dependent_user }].freeze

  setup do
    @first_guardian = create(:constituent, email: 'first-guardian@example.com', phone: '202-555-0101', phone_type: 'voice',
                                           communication_preference: 'email', locale: 'en')
    @second_guardian = create(:constituent, email: 'second-guardian@example.com', phone: '202-555-0102', phone_type: 'text',
                                            communication_preference: 'letter', locale: 'es')
    @dependent = create(:constituent, email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local", dependent_email: 'second-guardian@example.com',
                                      dependent_phone: '202-555-0102', phone: '000-123-4567')
    # The later guardian is linked first, so relationship order differs from guardian id order.
    @first_link = create(:guardian_relationship, guardian_user: @second_guardian, dependent_user: @dependent)
    @second_link = create(:guardian_relationship, guardian_user: @first_guardian, dependent_user: @dependent)
  end

  def contact_facts(user)
    {
      guardian: user.guardian_for_contact&.id, email: user.effective_email, phone: user.effective_phone,
      phone_type: user.effective_phone_type, preference: user.effective_communication_preference, locale: user.effective_locale,
      address_owner: user.dependent_mailing_address_owner(contact_guardian: user.guardian_for_contact)&.id
    }
  end

  test 'preloaded and lazy associations resolve the same contact for a dependent with several guardians' do
    assert_equal contact_facts(User.find(@dependent.id)), contact_facts(User.preload(*PRELOADS).find(@dependent.id))
  end

  test 'the contact guardian is the first relationship, not the lowest guardian id' do
    expected = @first_link.guardian_id

    assert_equal expected, User.find(@dependent.id).guardian_for_contact.id
    assert_equal expected, User.preload(*PRELOADS).find(@dependent.id).guardian_for_contact.id
  end

  test 'preloaded associations answer the table predicates and counts without further queries' do
    users = User.preload(*PRELOADS).where(id: [@dependent.id, @first_guardian.id]).to_a

    queries = capture_queries do
      users.each do |user|
        user.guardian?
        user.dependent?
        user.guardian_relationships_as_guardian.size
        user.guardians.to_a
        contact_facts(user)
      end
    end

    assert_empty queries
  end

  private

  def capture_queries(&)
    queries = []
    callback = lambda do |*, payload|
      queries << payload[:sql] unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    queries
  end
end
