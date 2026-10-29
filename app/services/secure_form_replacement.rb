# frozen_string_literal: true

# Replaces a subject's open secure links with one new link, for every secure form type.
# The caller owns the transaction, the subject lock (application or vendor), and which
# links count as open. The form class comes from the open relation.
class SecureFormReplacement
  def self.replace!(...) = new(...).replace!

  def initialize(open:, actor:, attributes:, request_batch_id: nil)
    @open = open
    @actor = actor
    @attributes = attributes
    @request_batch_id = request_batch_id
  end

  # Raises CooldownActive, changing nothing, while the latest open link is inside the resend cooldown.
  # Returns the SecureTokenizable::IssuedRequest of the new link.
  def replace!
    minutes = SecureFormPolicy.resend_cooldown_minutes(@open.order(sent_at: :desc).first)
    raise Applications::SecureRequestIssuance::CooldownActive, minutes if minutes

    @open.order(:id).lock.each { |form| form.revoke!(actor: @actor, reason: :replacement_request) }
    @open.klass.create_with_public_token!(request_attributes)
  end

  private

  def request_attributes
    @attributes.merge(
      status: :sent,
      request_batch_id: @request_batch_id,
      expires_at: SecureFormPolicy.expires_at,
      sent_at: Time.current,
      requested_by: @actor
    )
  end
end
