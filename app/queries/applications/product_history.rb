# frozen_string_literal: true

module Applications
  # The caller supplies applications it has already authorized for this viewer.
  class ProductHistory
    Source = Data.define(:kind, :occurred_on)
    Entry = Data.define(:product, :sources)
    Group = Data.define(:beneficiary, :entries)

    def initialize(applications:)
      @applications = applications
    end

    def groups
      @groups ||= begin
        entries = Hash.new { |beneficiaries, id| beneficiaries[id] = {} }
        purchase_lines.each do |line|
          application = line.voucher_transaction.voucher.application
          add(entries, application, line.product, :voucher_purchase, line.voucher_transaction.processed_at.to_date)
        end
        shipped_items.each do |item|
          add(entries, item.application, item.product, :program_shipment, item.shipped_at)
        end
        beneficiaries = @applications.includes(:user).to_a.index_by(&:user_id)
        entries.sort_by { |id, _| [beneficiaries.fetch(id).user.full_name, id] }.map do |id, products|
          Group.new(beneficiary: beneficiaries.fetch(id).user,
                    entries: products.values.sort_by { |entry| [entry.product.manufacturer, entry.product.name, entry.product.id] })
        end
      end
    end

    def products
      groups.flat_map(&:entries).map(&:product).uniq(&:id)
    end

    def find_product!(id)
      products.find { |product| product.id.to_s == id.to_s } || raise(ActiveRecord::RecordNotFound)
    end

    private

    def purchase_lines
      VoucherTransactionProduct.joins(voucher_transaction: :voucher)
                               .merge(VoucherTransaction.fulfillable)
                               .where(vouchers: { application_id: @applications.select(:id) })
                               .includes(:product, voucher_transaction: { voucher: { application: :user } })
                               .order(:id)
    end

    def shipped_items
      EquipmentItem.shipped.where(application_id: @applications.select(:id))
                   .includes(:product, application: :user).order(:id)
    end

    def add(entries, application, product, kind, date)
      entry = entries[application.user_id][product.id] ||= Entry.new(product: product, sources: [])
      source = Source.new(kind: kind, occurred_on: date)
      entry.sources << source unless entry.sources.include?(source)
      entry.sources.sort_by! { |each| [each.occurred_on, each.kind.to_s] }
    end
  end
end
