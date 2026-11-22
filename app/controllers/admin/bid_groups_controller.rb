# frozen_string_literal: true

module Admin
  class BidGroupsController < BaseController
    include EquipmentFormHandling

    def index
      @return_context = Equipment::RequestParameters.return_context(params)
      @groups = BidGroup.order(created_at: :desc)
      @groups = @groups.program_stock if params[:purpose] == 'program_stock'
      @groups = @groups.open if params[:state] == 'open'
      if params[:application_id].present?
        lines = BidGroupLine.left_joins(:equipment_need, :equipment_item)
        matches = lines.where(equipment_needs: { application_id: params[:application_id] })
                       .or(lines.where(equipment_items: { application_id: params[:application_id] }))
        @groups = @groups.where(id: matches.select(:bid_group_id))
      end
      @awaiting_award_ids = @groups.awaiting_award.ids
    end

    def show
      @group = BidGroup.includes(bid_group_lines: :product).find(params.expect(:id))
      need_lines = @group.bid_group_lines.select(&:equipment_need_id?)
      item_lines = @group.bid_group_lines.select(&:equipment_item_id?)
      ActiveRecord::Associations::Preloader.new(records: need_lines, associations: { equipment_need: :application }).call if need_lines.any?
      ActiveRecord::Associations::Preloader.new(records: item_lines, associations: { equipment_item: :application }).call if item_lines.any?
      @return_context = Equipment::RequestParameters.return_context(params)
      @has_active_lines = @group.bid_group_lines.any? { |line| !line.released_at? }
      @history = @group.equipment_history.to_a
      @equipment_audit_records = Equipment::AuditRecords.for(@history)
    end

    def new
      @return_context = Equipment::RequestParameters.return_context(params)
      selection = Equipment::Queue.new.selection(**params.permit(need_ids: [], item_ids: []).to_h.symbolize_keys)
      @need_rows = selection[:needs].map do |need|
        { id: need.id, quantity: params.dig(:quantities, need.id.to_s).presence || need.available_quantity, lock_version: need.lock_version }
      end
      @item_rows = selection[:items].map { |item| { id: item.id, lock_version: item.lock_version } }
      @stock_rows = params.permit(stock: [%i[product_id quantity supplier_setup_group]])[:stock].to_a.map(&:to_h).reject { |row| row['quantity'].to_s == '0' }
      raise Equipment::Conflict, 'Select devices or stock quantities before starting a bid.' if @need_rows.empty? && @item_rows.empty? && @stock_rows.empty?

      load_review
    rescue Equipment::Conflict => e
      redirect_to(params[:stock].present? ? admin_stock_index_path : admin_equipment_index_path(@return_context),
                  alert: e.message, status: :see_other)
    end

    def create
      @return_context = Equipment::RequestParameters.return_context(params)
      data = params.expect(bid_group: [:number, :purpose, :funding_source, :existing,
                                       { needs: [%i[id quantity lock_version]], items: [%i[id lock_version]], stock: [%i[product_id quantity supplier_setup_group]] }])
      @need_rows = data[:needs].to_a.map { |row| row.to_h.symbolize_keys }
      @item_rows = data[:items].to_a.map { |row| row.to_h.symbolize_keys }
      @stock_rows = data[:stock].to_a.map(&:to_h).reject { |row| row['quantity'].to_s == '0' }
      @number, @purpose = data.values_at(:number, :purpose)
      @funding_source = data[:funding_source].presence || 'mat'
      @existing = data[:existing]
      group = Equipment::Bidding.new(actor: current_user).create!(number: @number, purpose: @purpose, needs: @need_rows, items: @item_rows, stock: @stock_rows,
                                                                  funding_source: @funding_source, existing: @existing)
      redirect_to admin_bid_group_path(group, return_context: @return_context), notice: 'Bid reserved. Review current lines before awarding.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      @form_errors = equipment_form_errors(e)
      load_review
      render :new, status: :unprocessable_content
    end

    def update
      group = BidGroup.find(params.expect(:id))
      service = Equipment::Bidding.new(actor: current_user)
      if params[:amend_quantities] == '1'
        rows = params.expect(lines: [%i[id quantity lock_version]])
        service.change_quantities!(group: group, rows: rows.map(&:to_h), expected_version: params[:expected_version], reason: params[:reason])
      else
        service.release!(group: group, line_ids: params[:line_ids], expected_version: params[:expected_version], reason: params[:reason], cancel: params[:cancel] == '1')
      end
      redirect_to admin_bid_group_path(group), notice: 'Bid contents updated.', status: :see_other
    rescue Equipment::Conflict, ActiveRecord::RecordInvalid => e
      redirect_to admin_bid_group_path(group), alert: e.message, status: :see_other
    end

    private

    def load_review
      @purpose ||= @stock_rows.present? ? 'program_stock' : 'direct_to_constituents'
      @needs = EquipmentNeed.includes(:product, application: :user).where(id: @need_rows.pluck(:id)).index_by(&:id)
      @items = EquipmentItem.includes(:product, application: :user).where(id: @item_rows.pluck(:id)).index_by(&:id)
      @voucher_requests = (@needs.values + @items.values).any? { |request| request.application&.voucher_fulfillment? }
      @funding_source ||= 'mat'
      @icanconnect_active = @purpose != 'program_stock' && ::Icanconnect::Setting.active?
      @open_options = open_bid_options
      @stock_products = Product.where(id: @stock_rows.map { |row| row['product_id'] || row[:product_id] }).index_by { |product| product.id.to_s }
    end

    def open_bid_options
      groups = BidGroup.open.where(purpose: @purpose).order(:number)
      groups = groups.where(funding_source: 'mat') unless @icanconnect_active
      groups = groups.where(funding_source: 'icanconnect') if @voucher_requests
      options = groups.map do |group|
        funding = group.funding_source == 'icanconnect' ? 'iCanConnect' : 'MAT'
        ["#{group.number} · #{group.purpose.humanize} · #{funding}", "#{group.id}:#{group.lock_version}"]
      end
      options << ['Previous bid selection changed — review its current contents', @existing] if @existing.present? && options.none? { |_label, value| value == @existing }
      options
    end
  end
end
