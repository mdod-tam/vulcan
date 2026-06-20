# frozen_string_literal: true

class AccessibleLinkTestMailer < ApplicationMailer
  Template = Struct.new(:subject, :body) do
    def enabled? = true
    def name = 'accessible_link_test'
    def render(**) = [subject, body]
  end

  def labelled_link
    template = Template.new('Accessible link test', params[:body])

    send_email('recipient@example.test', template, {})
  end
end
