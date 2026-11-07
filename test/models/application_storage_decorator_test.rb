# frozen_string_literal: true

require 'test_helper'

class ApplicationStorageDecoratorTest < ActiveSupport::TestCase
  PROOF_NAMES = %w[income_proof residency_proof id_proof disability_certification].freeze

  test 'id proof attachment status uses preloaded attachment index' do
    application = create(:application)
    application.association(:id_proof_attachment).reset
    decorator = ApplicationStorageDecorator.new(application, Set['id_proof'])

    assert_no_sql_queries do
      assert decorator.id_proof_attached?
    end
  end

  test 'id proof attachment status is false when absent from preloaded attachment index' do
    application = create(:application)
    application.association(:id_proof_attachment).reset
    decorator = ApplicationStorageDecorator.new(application, Set.new)

    assert_no_sql_queries do
      assert_not decorator.id_proof_attached?
    end
  end

  test 'each attachment predicate answers from the preloaded names, and only for its own name' do
    PROOF_NAMES.each do |preloaded|
      application = create(:application)
      PROOF_NAMES.each { |name| application.association(:"#{name}_attachment").reset }
      decorator = ApplicationStorageDecorator.new(application, Set[preloaded])

      assert_no_sql_queries do
        PROOF_NAMES.each do |asked|
          assert_equal asked == preloaded, decorator.public_send(:"#{asked}_attached?"),
                       "#{asked}_attached? with only #{preloaded} preloaded"
        end
      end
    end
  end

  test 'a loaded attachment association answers before the preloaded names do' do
    PROOF_NAMES.each do |attached|
      application = create(:application, :"with_#{attached}")
      application.reload
      PROOF_NAMES.each { |name| application.public_send(:"#{name}_attachment") }
      decorator = ApplicationStorageDecorator.new(application, Set.new)

      assert_no_sql_queries do
        PROOF_NAMES.each do |asked|
          assert_equal asked == attached, decorator.public_send(:"#{asked}_attached?"),
                       "#{asked}_attached? with only #{attached} attached and no names preloaded"
        end
      end

      claims_all = ApplicationStorageDecorator.new(application, Set.new(PROOF_NAMES))
      assert_no_sql_queries do
        assert_equal [attached], PROOF_NAMES.select { |name| claims_all.public_send(:"#{name}_attached?") },
                     'a loaded association must win over a preloaded name that claims more'
      end
    end
  end

  test 'attachment preload names include id proof' do
    assert_includes ApplicationDataLoading::DEFAULT_ATTACHMENT_NAMES, 'id_proof'
  end

  private

  def assert_no_sql_queries(&)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      queries << payload[:sql] unless ignored_sql_notification?(payload)
    end

    yield

    assert_empty queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def ignored_sql_notification?(payload)
    payload[:cached] ||
      payload[:name].in?(%w[SCHEMA TRANSACTION]) ||
      payload[:sql].match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT)/i)
  end
end
