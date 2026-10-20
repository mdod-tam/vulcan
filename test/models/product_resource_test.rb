# frozen_string_literal: true

require 'test_helper'

class ProductResourceTest < ActiveSupport::TestCase
  test 'resources require one exact product, title, supported language, and exactly one source' do
    resource = build(:product_resource, product: nil, title: '', locale: 'xx', url: nil)
    assert_not resource.valid?
    %i[product title locale base].each { |attribute| assert resource.errors[attribute].present?, attribute }

    resource = build(:product_resource)
    resource.document.attach(pdf_blob)
    assert_not resource.valid?
    assert resource.errors[:base].present?
    resource.url = nil
    assert resource.valid?
  end

  test 'external guidance and manufacturer metadata use the same absolute web URL policy' do
    ['javascript:alert(1)', '//example.org/guide', 'https://user:secret@example.org/guide', "https://example.org/a\nb", 'https://', 'file:///guide.pdf'].each do |url|
      resource = build(:product_resource, url: url)
      assert_not resource.valid?, url
      assert_not build(:product, documentation_url: url).valid?, url
    end
    %w[https://example.org/guide?lang=es http://example.org/video].each do |url|
      assert build(:product_resource, url: url).valid?, url
      assert build(:product, documentation_url: url).valid?, url
    end
  end

  test 'ordering is title within language with deterministic ties and exact product targeting' do
    product = create(:product)
    later = create(:product_resource, product: product, title: 'Zulu', locale: 'en')
    spanish = create(:product_resource, product: product, title: 'Ayuda', locale: 'es')
    first = create(:product_resource, product: product, title: 'Alpha', locale: 'en')
    tie = create(:product_resource, product: product, title: 'Alpha', locale: 'en')
    assert_equal [first, tie, later, spanish], product.product_resources.by_language_and_title.to_a
    assert_empty create(:product).product_resources
  end

  private

  def pdf_blob
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new("%PDF-1.4\n#{'x' * 1024}"), filename: 'guide.pdf', content_type: 'application/pdf')
  end
end
