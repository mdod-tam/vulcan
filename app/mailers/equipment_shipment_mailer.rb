# frozen_string_literal: true

class EquipmentShipmentMailer < ApplicationMailer
  helper EquipmentHelper

  def shipped(application, notice)
    item = application.equipment_items.active.find_by(id: notice.metadata['equipment_item_id'])
    contact = Applications::ContactContext.new(application: application)
    unless application.status_approved? && item&.shipped_at? && contact.email_owner&.id == notice.recipient_id &&
           notice.metadata['contact_key'] == Equipment::ShipmentNotice.contact_key(contact) &&
           notice.metadata['package_key'] == Equipment::ShipmentNotice.package_key(item)
      raise DeliverySkipped.new(reason: :delivery_identity_changed)
    end

    @tracking_item = item
    @carrier = EquipmentItem::CARRIERS[item.carrier] unless item.carrier == 'other'
    @locale = normalize_locale(contact.email_locale) || I18n.default_locale
    @corrected = notice.metadata['corrected']
    @greeting = copy(:greeting, name: contact.email_owner.first_name)
    @intro = shipment_intro(application, contact.email_owner, item)
    @help = copy(:help, email: ProgramContact.support_email)
    @signature = copy(:signature)
    address = record_delivery_contact(contact.email, recipient: application.user, owner: contact.email_owner)
    mail(to: address, subject: copy(@corrected ? :corrected_subject : :subject), message_stream: 'notifications') do |format|
      tracking = [item.tracking_number, ("(#{@carrier})" if @carrier)].compact.join(' ')
      format.text { render plain: [@greeting, @intro, "#{copy(:tracking_label)} — #{tracking}", @help, @signature].join("\n\n") }
      format.html
    end
  end

  private

  def shipment_intro(application, recipient, item)
    values = { date: I18n.l(item.shipped_at, format: :long, locale: @locale), name: application.user.first_name }
    key = recipient.id == application.user_id ? :intro : :guardian_intro
    copy(@corrected ? "corrected_#{key}" : key, **values)
  end

  def copy(key, **variables)
    I18n.t("equipment_shipping.#{key}", locale: @locale, **variables)
  end
end
