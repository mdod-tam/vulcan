# frozen_string_literal: true

module ActionMailboxTestHelper
  require 'base64'
  # Reuse mailbox utilities when available
  include MailboxTestHelper if defined?(MailboxTestHelper)
  def self.included(base)
    base.class_eval do
      require 'action_mailbox/test_helper'
      include ActionMailbox::TestHelper
    end
  end

  # Assert that an email would be routed to the expected mailbox
  #
  # @param mailbox_class [Class] The mailbox you expect to match
  # @param kwargs        Mail attributes (:to, :from, :subject, etc.)
  #
  def assert_mailbox_routed(mailbox_class, **kwargs)
    mail = Mail.new({ to: 'nobody@example.com',
                      from: 'test@example.com' }.merge(kwargs))

    inbound_email = create_inbound_email_from_source(mail.to_s)

    routed_mailbox = ApplicationMailbox.router.mailbox_for(inbound_email)

    assert_equal mailbox_class, routed_mailbox,
                 "Expected message #{kwargs.inspect} to route to #{mailbox_class}, " \
                 "but it was routed to #{routed_mailbox || 'nothing'}"
  end

  # Helper to create an inbound email without attachments
  def create_inbound_email_from_attributes(to:, from:, subject: 'Test Email', body: 'Test Body')
    mail = Mail.new do
      to to
      from from
      subject subject
      body body
    end

    ActionMailbox::InboundEmail.create_and_extract_message_id!(mail.to_s)
  end

  # Helper to create an inbound email with attachments
  def create_inbound_email_with_attachment(to:, from:, subject:, body:, attachment_path:, content_type:)
    # Prefer unified helper if available
    if respond_to?(:create_email_attachment) && respond_to?(:create_inbound_email_with_attachments)
      file_content = File.read(attachment_path)
      if file_content.bytesize < 1024
        file_content = case content_type
                       when 'application/pdf'
                         generate_minimal_pdf_content
                       when 'image/jpeg', 'image/png'
                         file_content + ("\x00" * (1024 - file_content.bytesize + 100))
                       else
                         file_content + ('A' * (1024 - file_content.bytesize + 100))
                       end
      end

      attachment = Mail::Part.new
      attachment.content_type = content_type
      attachment.content_disposition = "attachment; filename=#{File.basename(attachment_path)}"
      attachment.content_transfer_encoding = 'base64'
      attachment.body = Base64.encode64(file_content)

      return create_inbound_email_with_attachments(
        from: from,
        to: to,
        subject: subject,
        body: body,
        attachments: [attachment]
      )
    end

    # Fallback to direct construction
    file_content = File.read(attachment_path)
    if file_content.bytesize < 1024
      file_content = case content_type
                     when 'application/pdf'
                       generate_minimal_pdf_content
                     when 'image/jpeg', 'image/png'
                       file_content + ("\x00" * (1024 - file_content.bytesize + 100))
                     else
                       file_content + ('A' * (1024 - file_content.bytesize + 100))
                     end
    end

    mail = Mail.new do
      to to
      from from
      subject subject

      text_part do
        body body
      end

      add_file filename: File.basename(attachment_path),
               content: file_content,
               content_type: content_type
    end

    ActionMailbox::InboundEmail.create_and_extract_message_id!(mail.to_s)
  end

  # This method is expected by the tests but was missing
  def receive_inbound_email_from_mail(to:, from:, subject: 'Test Email', body: 'Test Body', attachments: nil)
    mail = Mail.new do
      to to
      from from
      subject subject

      if attachments.nil?
        body body
      else
        text_part do
          body body
        end

        attachments.each do |attachment|
          # Ensure attachment content meets minimum size requirements
          content = attachment[:content]
          content += ('A' * (1024 - content.bytesize + 100)) if content.bytesize < 1024

          add_file(
            filename: attachment[:filename],
            content: content,
            content_type: attachment[:content_type]
          )
        end
      end
    end

    inbound_email = ActionMailbox::InboundEmail.create_and_extract_message_id!(mail.to_s)
    inbound_email.route
    inbound_email
  end

  private

  def generate_minimal_pdf_content
    # Generate a minimal valid PDF that's over 1KB
    pdf_header = "%PDF-1.4\n"
    pdf_content = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
    pdf_content += "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
    pdf_content += "3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>\nendobj\n"
    pdf_content += "4 0 obj\n<< /Length 44 >>\nstream\nBT\n/F1 12 Tf\n100 700 Td\n(Test PDF) Tj\nET\nendstream\nendobj\n"

    # Pad to ensure it's over 1KB
    padding = "%#{'A' * (1024 - (pdf_header + pdf_content).bytesize + 100)}\n"
    pdf_content += padding

    pdf_trailer = "xref\n0 5\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \n0000000179 00000 n \ntrailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n#{(pdf_header + pdf_content).bytesize}\n%%EOF\n"

    pdf_header + pdf_content + pdf_trailer
  end
end
