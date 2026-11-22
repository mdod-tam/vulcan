# frozen_string_literal: true

require 'test_helper'

module Icanconnect
  class FundingTest < ActiveSupport::TestCase
    include IcanconnectTestSupport

    setup do
      start_icanconnect!
      @admin = create(:admin)
    end

    test 'ICC funding opens on the start date and cannot cover earlier work' do
      application = approved_deafblind_application
      setting = Setting.find(Setting::ID)
      setting.destroy!
      assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'icanconnect') }
      assert_nothing_raised { Funding.validate!(application, source: 'mat') }

      launch = Date.tomorrow
      start_icanconnect!(on: launch)
      assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'icanconnect', on: launch) }

      travel_to launch.in_time_zone.noon do
        assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'icanconnect', on: launch.prev_day) }
        assert_nothing_raised { Funding.validate!(application, source: 'icanconnect', on: launch) }
      end
    end

    test 'one approved DeafBlind application can receive both MAT and iCanConnect devices' do
      application = approved_deafblind_application
      order, icc_unit = icc_order_with_unit(application: application)
      mat_unit = create(:equipment_item, application: application, funding_source: 'mat')
      assert_equal %w[icanconnect mat], application.equipment_items.pluck(:funding_source).sort
      assert_equal 'icanconnect', order.funding_source
      assert_equal 'mat', mat_unit.funding_source
      assert_equal application.id, icc_unit.application_id
    end

    test 'ICC attribution uses ordinary approved proof and still requires income when MAT does not' do
      application = approved_deafblind_application
      application.update!(income_proof_required: false, income_proof_status: :not_reviewed)
      assert_nothing_raised { Funding.validate!(application, source: 'mat') }
      assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'icanconnect') }
      application.update!(income_proof_status: :approved)
      assert_nothing_raised { Funding.validate!(application, source: 'icanconnect') }
      assert_raises(Funding::Ineligible) { Funding.validate!(application, source: 'other') }
    end

    test 'service completion records its date with MAT funding until staff chooses ICC' do
      application = approved_deafblind_application
      service = build(:evaluation, application: application)
      ServiceFunding.snapshot!(service, service_date: Date.current)
      assert_equal 'mat', service.funding_source
      assert_equal Date.current, service.funding_service_on
    end
  end
end
