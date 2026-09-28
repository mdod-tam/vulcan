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

    test 'compatibility views derive from the catalog' do
      assert_equal Catalog.mailer_map, NotificationService::MAILER_MAP
      assert_includes NotificationService::NOOP_DELIVERY_ACTIONS, 'w9_rejected'
      assert_equal %w[id_proof_rejected income_proof_rejected proof_rejected residency_proof_rejected],
                   NotificationService::ORPHAN_PROOF_REJECTION_DELIVERY_ACTIONS.sort
      assert_equal ['security_key_recovery_approved'], NotificationService::EMAIL_ONLY_ACTIONS
      assert_equal Catalog.notification_template_aliases, EmailTemplates::Audit::ACTION_TEMPLATE_ALIASES
    end

    test 'an unclassified delivery is blocked and recorded' do
      decision = Policy.verify_delivery('UnclassifiedProbeMailer#probe_notice', Policy.capture(mail_action: 'x'))

      assert decision.configuration_error?
      assert_equal 'unclassified_action', decision.reason
    end
  end
end
