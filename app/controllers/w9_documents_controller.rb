# frozen_string_literal: true

class W9DocumentsController < ApplicationController
  include ActiveStorage::Streaming

  before_action :authenticate_user!

  def show
    vendor = current_user.admin? ? Users::Vendor.find(params.expect(:vendor_id)) : current_user
    return head :not_found unless vendor.vendor? && vendor.id.to_s == params[:vendor_id].to_s

    blob = authorized_blob(vendor)
    return head :not_found unless blob

    response.headers['Cache-Control'] = 'private, no-store, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Vary'] = 'Cookie'
    if request.headers['Range'].present?
      send_blob_byte_range_data(blob, request.headers['Range'], disposition: disposition)
    else
      send_blob_stream(blob, disposition: disposition)
    end
  rescue ActiveRecord::RecordNotFound, ActiveStorage::FileNotFoundError
    head :not_found
  end

  private

  def disposition = params[:disposition] == 'attachment' ? 'attachment' : 'inline'

  def authorized_blob(vendor)
    return Vendors::W9Document.restorable(params[:reference], vendor: vendor) if params[:reference].present?

    blob_id = params[:id].to_s
    current = vendor.w9_form.blob
    return current if current && current.id.to_s == blob_id
    return unless current_user.admin?

    vendor.w9_archive.blobs.find_by(id: blob_id)
  end
end
