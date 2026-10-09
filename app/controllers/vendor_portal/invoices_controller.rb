# frozen_string_literal: true

module VendorPortal
  class InvoicesController < VendorPortal::BaseController
    include Pagy::Backend

    before_action :set_invoice, only: [:show]

    # GET /vendor/invoices
    def index
      @pagy, @invoices = pagy(current_user.invoices.order(created_at: :desc, id: :desc), limit: 20)
    end

    # GET /vendor/invoices/:id
    def show
      # @invoice is set by set_invoice
    end

    private

    def set_invoice
      @invoice = current_user.invoices.find_by(id: params[:id])
      redirect_to vendor_portal_invoices_path, alert: 'Invoice not found.' unless @invoice
    end
  end
end
