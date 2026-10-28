# frozen_string_literal: true

require 'test_helper'

module EmailDelivery
  # Required CI check: every sending mailer action is classified and every dispatch contract fits.
  class CatalogTest < ActiveSupport::TestCase
    test 'every application mailer action is in the catalog' do
      assert_empty CatalogCoverage.unclassified_actions,
                   'Classify these actions in EmailDelivery::Catalog::MAIL_ACTIONS'
    end

    test 'the coverage check reports an action nobody classified' do
      mailer = Class.new(ApplicationMailer) do
        def self.name = 'UnclassifiedProbeMailer'

        def probe_notice; end
      end

      assert_equal ['UnclassifiedProbeMailer#probe_notice'], CatalogCoverage.unclassified_actions([mailer])
    end

    test 'every catalog mail action still exists' do
      assert_empty CatalogCoverage.stale_entries
    end

    test 'every notification adapter matches its mailer signature' do
      assert_empty CatalogCoverage.incompatible_dispatch_contracts
    end

    test 'categories are the nine delivery categories' do
      used = Catalog::MAIL_ACTIONS.values.map(&:category).uniq - ['from_test_template']

      assert_empty used - Catalog::CATEGORIES
    end

    test 'notification mapping belongs to the catalog' do
      assert_predicate Catalog.notification_action('w9_rejected'), :audit_only?
      assert_equal 'MedicalProviderMailer#requested', Catalog.notification_action('disability_certification_requested').mail_action
      assert_equal :notifiable_and_notification, Catalog.notification_action('training_requested').adapter
      assert_nil Catalog.notification_action('proof_rejected')
      assert_nil Catalog.notification_action('disability_certification_rejected')
      assert_nil Catalog.notification_action('some_unknown_action')
      assert_equal Catalog.notification_template_aliases, EmailTemplates::Audit::ACTION_TEMPLATE_ALIASES
    end

    test 'an unclassified delivery is blocked and recorded' do
      decision = Policy.verify_delivery('UnclassifiedProbeMailer#probe_notice', Policy.capture(mail_action: 'x'))

      assert decision.configuration_error?
      assert_equal 'unclassified_action', decision.reason
    end
  end
end
