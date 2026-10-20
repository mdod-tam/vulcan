# frozen_string_literal: true

require 'test_helper'

class ProductResourceParameterFilterTest < ActiveSupport::TestCase
  test 'resource uploads and query bearing URLs are filtered without hiding structural resource fields' do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      'product_resource' => { 'title' => 'Getting started', 'locale' => 'en', 'source' => 'url',
                              'url' => 'https://example.org/guide?token=private', 'document' => 'file-body',
                              'document_signed_id' => 'signed-private-reference' },
      'product' => { 'documentation_url' => 'https://example.org/docs?token=private' }
    )
    %w[url document document_signed_id].each { |field| assert_equal '[FILTERED]', filtered['product_resource'][field] }
    assert_equal '[FILTERED]', filtered['product']['documentation_url']
    assert_equal 'Getting started', filtered['product_resource']['title']
    assert_equal 'en', filtered['product_resource']['locale']
    assert_equal 'url', filtered['product_resource']['source']
  end

  test 'SQL inspection filters resource and manufacturer URLs' do
    resource = build(:product_resource, url: 'https://example.org/guide?credential=private-sentinel')
    product = build(:product, documentation_url: 'https://example.org/guide?credential=private-sentinel')
    assert_not_includes resource.inspect, 'private-sentinel'
    assert_not_includes product.inspect, 'private-sentinel'
    assert_includes resource.inspect, '[FILTERED]'
  end
end
