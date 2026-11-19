# frozen_string_literal: true

module Applications
  # The supplied relation is the authorization boundary for both modes.
  class ProductHistory
    MODES = %i[fulfilled portal_visible].freeze
    Source = Data.define(:occurred_on, :identity, :quantity, :status, :application_id)
    Entry = Data.define(:product, :sources)
    Group = Data.define(:beneficiary, :entries)

    def initialize(applications:, mode: :fulfilled)
      raise ArgumentError, 'Unknown product history mode' unless MODES.include?(mode)

      @applications = applications
      @mode = mode
    end

    def groups
      @groups ||= begin
        entries = Hash.new { |beneficiaries, id| beneficiaries[id] = {} }
        purchase_lines.each do |line|
          application = line.voucher_transaction.voucher.application
          source = Source.new(occurred_on: line.voucher_transaction.processed_at.to_date,
                              identity: "purchase:#{line.id}", quantity: line.quantity, status: :voucher_purchase, application_id: application.id)
          add(entries, application, line.product, source)
        end
        equipment_items.each do |item|
          status = item_status(item)
          source = Source.new(occurred_on: item.shipped_at, identity: "equipment:#{item.id}",
                              quantity: 1, status:, application_id: item.application_id)
          add(entries, item.application, item.product, source)
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

    def fulfillment_in_progress?
      @applications.status_approved.fulfillment_type_equipment.includes(:equipment_needs, :equipment_items, :equipment_source_evaluation).any? do |application|
        application.equipment_items.any? { |item| !item.withdrawn_at? && item.shipped_at.nil? } ||
          application.equipment_needs.any? { |need| need.remaining_quantity.positive? } ||
          application.equipment_catalog_product_pending?
      end
    end

    private

    def purchase_lines
      VoucherTransactionProduct.joins(voucher_transaction: :voucher)
                               .merge(VoucherTransaction.fulfillable)
                               .where(vouchers: { application_id: @applications.select(:id) })
                               .includes({ product: { product_resources: { document_attachment: :blob } } },
                                         voucher_transaction: { voucher: { application: :user } })
                               .order(:id)
    end

    def equipment_items
      scope = @mode == :portal_visible ? EquipmentItem.portal_visible : EquipmentItem.shipped
      scope.where(application_id: @applications.select(:id))
           .includes({ product: { product_resources: { document_attachment: :blob } } }, :purchase_order, application: :user).order(:id)
    end

    def item_status(item)
      return :program_shipment if item.shipped_at?

      item.stock? ? :stock_preparation : :order_in_progress
    end

    def add(entries, application, product, source)
      entry = entries[application.user_id][product.id] ||= Entry.new(product:, sources: [])
      entry.sources << source
      entry.sources.sort_by! { |each| [each.occurred_on ? 0 : 1, each.occurred_on || Date.new(1), each.identity] }
    end
  end
end
