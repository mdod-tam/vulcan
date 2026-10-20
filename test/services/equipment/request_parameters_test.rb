# frozen_string_literal: true

require 'test_helper'

module Equipment
  class RequestParametersTest < ActiveSupport::TestCase
    test 'return context retains supported tabs and numeric filters from request parameters' do
      source = ActionController::Parameters.new(return_context: { tab: 'ordered', product_id: '7', vendor_id: '8', next: 'https://evil.example/' })
      assert_equal({ tab: 'ordered', product_id: '7', vendor_id: '8' }, RequestParameters.return_context(source))
      assert_equal({ tab: 'shipped', product_id: '9' }, RequestParameters.return_context('tab' => 'shipped', 'product_id' => 9))
    end

    test 'unknown navigation input cannot become a redirect destination or filter' do
      [nil, 'https://evil.example/', { return_context: 'https://evil.example/' },
       { return_to: 'https://evil.example/admin/equipment?tab=shipped' },
       { return_to: '//evil.example/admin/equipment' }, { tab: 'elsewhere', product_id: '-1', vendor_id: 'bad' }].each do |source|
        assert_equal({}, RequestParameters.return_context(source))
      end
    end

    test 'submitted record versions remain opaque strings while malformed map entries are excluded' do
      source = ActionController::Parameters.new('7' => '0002', '8' => 'stale-version', '9' => 3, 'bad' => '4')
      assert_equal({ '7' => '0002', '8' => 'stale-version' }, RequestParameters.record_versions(source))
      assert_equal({}, RequestParameters.record_versions(nil))
      assert_equal({}, RequestParameters.record_versions(%w[7 2]))
    end
  end
end
