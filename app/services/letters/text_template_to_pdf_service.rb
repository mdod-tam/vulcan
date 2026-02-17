# frozen_string_literal: true

module Letters
  # This service converts database-stored email text templates to PDFs for printing
  # It allows us to maintain a single source of templates (in the database with versioning logic)
  class TextTemplateToPdfService
    attr_reader :template_name, :format, :template, :variables, :recipient

    def initialize(template_name:, recipient:, variables: {})
      @template_name = template_name
      @format = :text
      @recipient = recipient
      @variables = variables
      @template = find_template
    end

    def generate_pdf
      return nil unless @template

      # Render the template with the provided variables
      rendered_content = render_template_with_variables

      # Create a PDF document using the rendered content
      pdf = Prawn::Document.new do |doc|
        setup_document(doc)
        # Conditionally add header and footer based on template requirements
        add_header(doc) unless template_requires_shared_partials?
        add_date(doc)
        add_address(doc)
        add_salutation(doc)
        add_body_content(doc, rendered_content)
        add_closing(doc)
        # Conditionally add header and footer based on template requirements
        add_footer(doc) unless template_requires_shared_partials?
        add_page_numbers(doc)
      end

      create_tempfile(pdf)
    end

    def queue_for_printing
      pdf_tempfile = generate_pdf
      return nil unless pdf_tempfile

      letter_type = determine_letter_type

      print_queue_item = PrintQueueItem.new(
        constituent: recipient,
        application: variables[:application],
        letter_type: letter_type
      )

      # Attach the PDF to the queue item
      print_queue_item.pdf_letter.attach(
        io: File.open(pdf_tempfile.path),
        filename: "#{letter_type}_#{recipient.id}.pdf",
        content_type: 'application/pdf'
      )

      print_queue_item.save!
      pdf_tempfile.close
      pdf_tempfile.unlink

      print_queue_item
    end

    private

    def find_template
      EmailTemplate.find_by(name: template_name, format: format)
    end

    def render_template_with_variables
      body = template.body.dup

      # Replace all placeholders with the actual values
      variables.each do |key, value|
        # Handle the %<key>s format (printf style)
        placeholder = "%<#{key}>s"
        body.gsub!(placeholder, value.to_s) if body.include?(placeholder)

        # Also handle the %{key} format for backward compatibility
        alt_placeholder = "%{#{key}}"
        body.gsub!(alt_placeholder, value.to_s) if body.include?(alt_placeholder)
      end

      body
    end

    def setup_document(pdf)
      pdf.font_size 11
      pdf.font 'Helvetica'
    end

    def add_header(pdf)
      # Add logo if available
      logo_path = Rails.root.join('app/assets/images/mat_logo.png')
      pdf.image(logo_path.to_s, width: 150) if File.exist?(logo_path)

      # Add title with template name stylized as a title
      pdf.move_down 20
      pdf.font_size 18
      pdf.text determine_letter_title, style: :bold, align: :center
      pdf.move_down 20
      pdf.font_size 11
    end

    def add_date(pdf)
      date_str = Time.current.strftime('%B %d, %Y')
      pdf.text "Date: #{date_str}", align: :right
      pdf.move_down 10
    end

    def add_address(pdf)
      address_lines = [
        recipient.full_name,
        recipient.physical_address_1,
        recipient.physical_address_2.presence,
        "#{recipient.city}, #{recipient.state} #{recipient.zip_code}"
      ].compact

      pdf.text address_lines.join("\n")
      pdf.move_down 20
    end

    def add_salutation(pdf)
      pdf.text "Dear #{recipient.first_name},"
      pdf.move_down 10
    end

    def add_body_content(pdf, content)
      # Split the content into paragraphs
      paragraphs = content.split(/\n\n+/)

      paragraphs.each do |paragraph|
        # Ignore empty paragraphs
        next if paragraph.strip.empty?

        # Format lists if they exist in the paragraph
        if paragraph.match(/^\s*[*\-•]\s+/)
          paragraph.split("\n").each do |list_item|
            if list_item.match(/^\s*[*\-•]\s+/)
              pdf.indent(10) do
                pdf.text list_item.gsub(/^\s*[*\-•]\s+/, '• ')
              end
            else
              pdf.text list_item
            end
          end
        else
          pdf.text paragraph
        end

        pdf.move_down 10
      end
    end

    def add_closing(pdf)
      pdf.move_down 30
      pdf.text 'Sincerely,'
      pdf.move_down 15
      pdf.text 'Maryland Accessible Telecommunications'
      pdf.text 'Customer Service Team'
    end

    def add_footer(pdf)
      pdf.move_down 50
      pdf.font_size 8
      pdf.stroke_horizontal_rule
      pdf.move_down 10
      pdf.text 'Maryland Accessible Telecommunications | 123 Main Street, Baltimore, MD 21201', align: :center
      pdf.text 'Phone: 555-123-4567 | Email: more.info@maryland.gov | Website: mdmat.org', align: :center
    end

    def add_page_numbers(pdf)
      pdf.number_pages 'Page <page> of <total>',
                       {
                         at: [pdf.bounds.right - 150, 0],
                         width: 150,
                         align: :right,
                         page_filter: :all,
                         start_count_at: 1
                       }
    end

    def create_tempfile(pdf)
      tempfile = Tempfile.new(['letter', '.pdf'])
      tempfile.binmode
      tempfile.write(pdf.render)
      tempfile.rewind
      tempfile
    end

    def determine_letter_title
      # Convert the template name into a human-readable title
      case template_name
      when 'application_notifications_account_created'
        'Your Maryland Accessible Telecommunications Account'
      when 'application_notifications_registration_confirmation'
        'Welcome to the Maryland Accessible Telecommunications Program'
      when 'application_notifications_proof_rejected'
        'Document Verification Follow-up Required'
      when 'application_notifications_income_threshold_exceeded'
        'Income Eligibility Review'
      when 'application_notifications_proof_approved'
        'Document Verification Approved'
      when 'application_notifications_proof_received'
        'Document Verification Received'
      when 'application_notifications_max_rejections_reached'
        'Important Application Status Update'
      when 'application_notifications_proof_submission_error'
        'Document Submission Error'
      when 'medical_provider_request_certification'
        'Request for Medical Certification'
      when 'voucher_notifications_voucher_assigned'
        'Your Accessibility Equipment Voucher'
      when 'voucher_notifications_voucher_redeemed'
        'Voucher Redemption Confirmation'
      when 'evaluator_mailer_evaluation_submission_confirmation'
        'Evaluation Submission Confirmation'
      else
        # If no specific title is defined, create one from the template name
        template_name.gsub('_', ' ').titleize
      end
    end

    def determine_letter_type
      # Convert the template name to a letter type symbol
      template_name.to_sym
    end

    # Check if the template requires shared partial variables (header_text and footer_text)
    def template_requires_shared_partials?
      template = EmailTemplate.find_by(name: template_name)
      return false unless template
      template.required_variables.include?('header_text') && template.required_variables.include?('footer_text')
    end
  end
end
