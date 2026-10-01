# frozen_string_literal: true

require 'test_helper'

module EmailDelivery
  class PairReconciliationTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @en = create(:email_template, :text, name: 'mixed_pair_probe', locale: 'en', enabled: true)
      @es = create(:email_template, :text, name: 'mixed_pair_probe', locale: 'es', enabled: true)
      @es.update_columns(enabled: false) # a legacy mismatch; normal writes cannot create one
      create(:email_template, :text, name: 'single_locale_probe', locale: 'en', enabled: true)
    end

    test 'the report names each mismatched pair and the locale that will stop sending' do
      report = PairReconciliation.report

      assert_match 'mixed_pair_probe (text): EN on, ES off -> stops EN', report
      assert_no_match(/single_locale_probe/, report)
      assert_no_match(/email_header_text|email_footer_text/, report)
    end

    test 'applying turns the whole pair off, audits it once, and never enables a disabled locale' do
      2.times { PairReconciliation.apply!(actor: @admin) }

      [@en, @es].each(&:reload)
      assert_not @en.enabled
      assert_not @es.enabled
      events = Event.where(action: ControlWriter::TEMPLATE_AUDIT_ACTION, auditable: [@en, @es])
      assert_equal 1, events.count
      assert_equal({ 'en' => true, 'es' => false }, events.sole.metadata['old_values'])
      assert_empty(PairReconciliation.mixed_pairs.select { |pair| pair.name == 'mixed_pair_probe' })
    end
  end
end
