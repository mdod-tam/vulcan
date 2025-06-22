# frozen_string_literal: true

class VendorNotificationsMailer < ApplicationMailer
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::NumberHelper # For number_to_currency
  # Include helpers for rendering shared partials (e.g., status boxes for W9)
  include Mailers::SharedPartialHelpers # Use the extracted shared helper module

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

    def invoice_generated
    invoice      = params[:invoice]
    vendor       = invoice.vendor
    transactions = invoice.voucher_transactions.includes(:voucher)

    variables = build_invoice_variables(invoice, vendor, transactions)
    subject, body = render_template('vendor_notifications_invoice_generated', variables)

    attachments["invoice-#{invoice.invoice_number}.pdf"] = generate_invoice_pdf(invoice, vendor, transactions)

    send_mail(vendor.email, subject, body)
  rescue => e
    log_mail_error(e, vendor, 'vendor_notifications_invoice_generated', variables.except(:transactions_html_table, :transactions_text_list))
    raise e
  end

  def payment_issued
    invoice = params[:invoice]
    vendor  = invoice.vendor

    variables = build_payment_variables(invoice, vendor)
    subject, body = render_template('vendor_notifications_payment_issued', variables)

    send_mail(vendor.email, subject, body)
  rescue => e
    log_mail_error(e, vendor, 'vendor_notifications_payment_issued', variables)
    raise e
  end

  def w9_approved
    vendor = params[:vendor]

    variables = build_w9_variables(vendor, :success, 'W9 Form Approved', 'W9 Approved', 'Your W9 form has been approved. No further action is needed at this time.')
    subject, body = render_template('vendor_notifications_w9_approved', variables)

    send_mail(vendor.email, subject, body)
  rescue => e
    log_mail_error(e, vendor, 'vendor_notifications_w9_approved', variables.except(:status_box_html, :header_html, :footer_html))
    raise e
  end

  def w9_rejected
    vendor     = params[:vendor]
    w9_review  = params[:w9_review]
    reason     = w9_review&.rejection_reason || 'No reason provided.'

    message = "Your W9 form requires attention. Reason: #{reason}. Please visit the vendor portal to upload a corrected form."
    variables = build_w9_variables(vendor, :error, 'W9 Form Requires Attention', 'W9 Rejected', message)
      .merge(rejection_reason: reason, vendor_portal_url: resolve_vendor_portal_url)

    subject, body = render_template('vendor_notifications_w9_rejected', variables)
    send_mail(vendor.email, subject, body, content_type: 'text/plain')
  rescue => e
    log_mail_error(e, vendor, 'vendor_notifications_w9_rejected', variables.except(:status_box_html, :header_html, :footer_html))
    raise e
  end

  def w9_expiring_soon
    vendor = params[:vendor]
    return unless vendor.w9_expiration_date.present?
    
    days_until_expiry = (vendor.w9_expiration_date - Date.current).to_i
    expiration_date_formatted = vendor.w9_expiration_date.strftime('%B %d, %Y')
    association_msg = vendor.associated? ? 'Your association requires a valid W9.' : ''

    warning_msg = "Your W9 form on file will expire in #{days_until_expiry} days on #{expiration_date_formatted}."
    info_msg    = "Please visit the vendor portal to upload a new W9 form to avoid any disruption. #{association_msg}"

    variables = build_w9_variables(vendor, :warning, 'W9 Form Expiring Soon', 'W9 Expiring Soon', warning_msg)
      .merge(
        status_box_info_text: status_box_text(status: :info, title: 'Action Required', message: info_msg),
        days_until_expiry: days_until_expiry,
        expiration_date_formatted: expiration_date_formatted,
        vendor_association_message: association_msg,
        vendor_portal_url: resolve_vendor_portal_url
      )

    subject, body = render_template('vendor_notifications_w9_expiring_soon', variables)
    send_mail(vendor.email, subject, body, content_type: 'text/plain')
  rescue => e
    log_mail_error(e, vendor, 'vendor_notifications_w9_expiring_soon', variables.except(:status_box_warning_html, :status_box_info_html, :header_html, :footer_html))
    raise e
  end

  def w9_expired
    vendor = params[:vendor]
    return unless vendor.w9_expiration_date.present?
    
    expiration_date_formatted = vendor.w9_expiration_date.strftime('%B %d, %Y')
    association_msg = vendor.associated? ? 'Your association requires a valid W9.' : ''

    warning_msg = "Your W9 form on file expired on #{expiration_date_formatted}."
    info_msg    = "Please visit the vendor portal immediately to upload a new W9 form to avoid payment delays. #{association_msg}"

    variables = build_w9_variables(vendor, :warning, 'W9 Form Has Expired - Action Required', 'W9 Expired', warning_msg)
      .merge(
        status_box_info_text: status_box_text(status: :info, title: 'Action Required', message: info_msg),
        expiration_date_formatted: expiration_date_formatted,
        vendor_association_message: association_msg,
        vendor_portal_url: resolve_vendor_portal_url
      )

    subject, body = render_template('vendor_notifications_w9_expired', variables)
    send_mail(vendor.email, subject, body, content_type: 'text/plain')
  rescue => e
    log_mail_error(e, vendor, 'vendor_notifications_w9_expired', variables.except(:status_box_warning_html, :status_box_info_html, :header_html, :footer_html))
    raise e
  end

  private

  def build_invoice_variables(invoice, vendor, transactions)
    {
      vendor_business_name: vendor.business_name,
      invoice_number: invoice.invoice_number,
      period_start_formatted: invoice.period_start.strftime('%B %d, %Y'),
      period_end_formatted: invoice.period_end.strftime('%B %d, %Y'),
      total_amount_formatted: number_to_currency(invoice.total_amount),
      transactions_html_table: render_transactions_html(transactions),
      transactions_text_list: render_transactions_text(transactions)
    }.compact
  end

  def build_payment_variables(invoice, vendor)
    {
      vendor_business_name: vendor.business_name,
      invoice_number: invoice.invoice_number,
      total_amount_formatted: number_to_currency(invoice.total_amount),
      gad_invoice_reference: invoice.gad_invoice_reference || 'N/A',
      check_number: invoice.check_number
    }.compact
  end

  def build_w9_variables(vendor, status, header_title, status_box_title, status_box_message)
    {
      vendor_business_name: vendor.business_name,
      header_title: header_title,
      status_box_text: status_box_text(status: status, title: status_box_title, message: status_box_message),
      header_text: header_text(title: header_title, logo_url: logo_url),
      footer_text: footer_text(organization_name: org_name, contact_email: support_email, website_url: org_url, show_automated_message: true),
      header_logo_url: logo_url,
      header_subtitle: nil
    }.compact
  end

  def render_template(template_name, variables)
    template = EmailTemplate.find_by!(name: template_name, format: :text)
    template.render(**variables)
  end

  def send_mail(to, subject, body, content_type: 'text/plain')
    mail(
      to: to,
      subject: subject,
      message_stream: 'outbound',
      body: body.to_s,
      content_type: content_type
    )
  end

  def log_mail_error(error, user, template_name, variables)
    Event.create!(
      user: user,
      action: 'email_delivery_error',
      user_agent: Current.user_agent,
      ip_address: Current.ip_address,
      metadata: {
        error_message: error.message,
        error_class: error.class.name,
        template_name: template_name,
        variables: variables,
        backtrace: error.backtrace&.first(5)
      }
    )
  end

  def render_transactions_html(transactions)
    '<table><thead><tr><th>Date</th><th>Voucher</th><th>Amount</th></tr></thead><tbody>' +
      transactions.map do |t|
        "<tr><td>#{t.processed_at.strftime('%Y-%m-%d')}</td><td>#{t.voucher.code}</td><td>#{number_to_currency(t.amount)}</td></tr>"
      end.join + '</tbody></table>'
  end

  def render_transactions_text(transactions)
    transactions.map do |t|
      "#{t.processed_at.strftime('%Y-%m-%d')} | #{t.voucher.code} | #{number_to_currency(t.amount)}"
    end.join("\n")
  end

  def logo_url
    ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host]) rescue nil
  end

  def support_email
    Policy.get('support_email') || 'support@example.com'
  end

  def org_name
    Policy.get('organization_name') || 'MAT Program'
  end

  def org_url
    root_url(host: default_url_options[:host])
  end

  def resolve_vendor_portal_url
    defined?(vendor_portal_root_url) ? vendor_portal_root_url(host: default_url_options[:host]) : org_url
  end

  # Updated to accept arguments instead of relying on instance variables
  def generate_invoice_pdf(invoice, vendor, transactions)
    pdf = Prawn::Document.new do |pdf|
      # Header
      pdf.text 'INVOICE', size: 24, style: :bold, align: :center
      pdf.move_down 20

      # Invoice Details
      pdf.text "Invoice Number: #{invoice.invoice_number}"
      pdf.text "Date: #{invoice.created_at.strftime('%B %d, %Y')}"
      pdf.move_down 20

      # Vendor Information
      pdf.text 'Vendor:', style: :bold
      pdf.text vendor.business_name
      pdf.text vendor.business_tax_id
      pdf.move_down 20

      # Period
      pdf.text 'Period:', style: :bold
      pdf.text "#{invoice.period_start.strftime('%B %d, %Y')} - #{invoice.period_end.strftime('%B %d, %Y')}"
      pdf.move_down 20

      # Transactions Table
      items = [%w[Date Voucher Amount]]
      transactions.each do |transaction|
        items << [
          transaction.processed_at.strftime('%Y-%m-%d'),
          transaction.voucher.code,
          number_to_currency(transaction.amount) # Use helper directly
        ]
      end

      pdf.table(items, header: true) do |table|
        table.row(0).style(background_color: 'CCCCCC')
        table.cells.padding = 12
        table.column_widths = [150, 200, 150]
      end

      pdf.move_down 20

      # Total
      pdf.text "Total Amount: #{number_to_currency(invoice.total_amount)}", # Use helper directly
               size: 14,
               style: :bold,
               align: :right

      # Footer
      pdf.move_down 40
      pdf.text 'Please allow up to 30 days for payment processing.', size: 10
      pdf.text "Contact #{Policy.get('support_email') || 'support@example.com'} for any questions.", size: 10 # Use Policy
    end

    pdf.render
  end
end
