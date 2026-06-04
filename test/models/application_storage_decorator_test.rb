# frozen_string_literal: true

require 'test_helper'

class ApplicationStorageDecoratorTest < ActiveSupport::TestCase
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

  test 'attachment preload names include id proof' do
    assert_includes ApplicationDataLoading::DEFAULT_ATTACHMENT_NAMES, 'id_proof'
    assert_includes Admin::ApplicationsController::WANTED_ATTACHMENT_NAMES, 'id_proof'
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
