# frozen_string_literal: true

module Letters
  # This service converts database-stored email text templates to PDFs for printing
  # It allows us to maintain a single source of templates (in the database with versioning logic)
  class TextTemplateToPdfService
    LETTER_TYPE_BY_TEMPLATE = {
      'application_notifications_account_created' => :account_created,
      'application_notifications_registration_confirmation' => :registration_confirmation,
      'application_notifications_income_threshold_exceeded' => :income_threshold_exceeded,
      'application_notifications_proof_approved' => :proof_approved,
      'application_notifications_max_rejections_reached' => :max_rejections_reached,
      'application_notifications_proof_submission_error' => :proof_submission_error,
      'evaluator_mailer_evaluation_submission_confirmation' => :evaluation_submitted
    }.freeze

    DEFAULT_LETTER_TITLES = {
      'application_notifications_account_created' => 'Your Maryland Accessible Telecommunications Account',
      'application_notifications_registration_confirmation' => 'Welcome to the Maryland Accessible Telecommunications Program',
      'application_notifications_proof_rejected' => 'Document Verification Follow-up Required',
      'application_notifications_income_threshold_exceeded' => 'Income Eligibility Review',
      'application_notifications_proof_approved' => 'Document Verification Approved',
      'application_notifications_proof_received' => 'Document Verification Received',
      'application_notifications_max_rejections_reached' => 'Important Application Status Update',
      'application_notifications_proof_submission_error' => 'Document Submission Error',
      'medical_provider_request_certification' => 'Request for Medical Certification',
      'voucher_notifications_voucher_assigned' => 'Your Accessibility Equipment Voucher',
      'voucher_notifications_voucher_redeemed' => 'Voucher Redemption Confirmation',
      'evaluator_mailer_evaluation_submission_confirmation' => 'Evaluation Submission Confirmation'
    }.freeze

    attr_reader :template_name, :format, :template, :variables, :recipient, :letter_type_override

    def initialize(template_name:, recipient:, variables: {}, letter_type: nil)
      @template_name = template_name
      @format = :text
      @recipient = recipient
      @variables = variables
      @letter_type_override = letter_type
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
      template = EmailTemplate.find_by(name: template_name, format: format, locale: resolved_locale)
      return template if template.present?

      return template if resolved_locale == I18n.default_locale.to_s

      EmailTemplate.find_by(name: template_name, format: format, locale: I18n.default_locale.to_s)
    end

    def render_template_with_variables
      interpolate_template_text(template.body)
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
      date_str = I18n.l(Time.current.to_date, format: :long, locale: resolved_locale.to_sym)
      pdf.text "#{I18n.t('letters.pdf.date_label', locale: resolved_locale)}: #{date_str}", align: :right
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
      pdf.text I18n.t('letters.pdf.salutation', first_name: recipient.first_name, locale: resolved_locale)
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
      pdf.text I18n.t('letters.pdf.closing', locale: resolved_locale)
      pdf.move_down 15
      pdf.text I18n.t('letters.pdf.signature.organization', locale: resolved_locale)
      pdf.text I18n.t('letters.pdf.signature.team', locale: resolved_locale)
    end

    def add_footer(pdf)
      pdf.move_down 50
      pdf.font_size 8
      pdf.stroke_horizontal_rule
      pdf.move_down 10
      support_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
      pdf.text I18n.t('letters.pdf.footer.address', locale: resolved_locale), align: :center
      pdf.text I18n.t('letters.pdf.footer.contact_line', support_email: support_email, locale: resolved_locale), align: :center
    end

    def add_page_numbers(pdf)
      page_number_text = I18n.t('letters.pdf.page_number', page: '<page>', total: '<total>', locale: resolved_locale)

      pdf.number_pages page_number_text,
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
      subject_title = interpolate_template_text(template.subject).strip
      return subject_title if subject_title.present?

      default_title = DEFAULT_LETTER_TITLES.fetch(template_name, template_name.gsub('_', ' ').titleize)
      I18n.t("letters.pdf.titles.#{template_name}", default: default_title, locale: resolved_locale)
    end

    def determine_letter_type
      candidate = letter_type_override || letter_type_from_template
      candidate = candidate.to_sym
      return candidate if PrintQueueItem.letter_types.key?(candidate.to_s)

      :other_notification
    end

    def letter_type_from_template
      return proof_rejected_letter_type if template_name == 'application_notifications_proof_rejected'

      LETTER_TYPE_BY_TEMPLATE.fetch(template_name, :other_notification)
    end

    def proof_rejected_letter_type
      proof_type = variables[:proof_type] || variables['proof_type']
      proof_type = proof_type.to_s
      case proof_type
      when 'income'
        :income_proof_rejected
      when 'residency'
        :residency_proof_rejected
      else
        :other_notification
      end
    end

    # Check if the template requires shared partial variables (header_text and footer_text)
    def template_requires_shared_partials?
      template = EmailTemplate.find_by(name: template_name, format: format, locale: resolved_locale) ||
                 EmailTemplate.find_by(name: template_name, format: format, locale: I18n.default_locale.to_s)
      return false unless template

      template.required_variables.include?('header_text') && template.required_variables.include?('footer_text')
    end

    def resolved_locale
      locale = recipient.locale if recipient.respond_to?(:locale)
      normalized = normalize_locale(locale)
      normalized || I18n.default_locale.to_s
    end

    def normalize_locale(locale)
      candidate = locale.to_s.strip
      return nil if candidate.empty?

      candidate.tr('_', '-').split('-').first.downcase
    end

    def interpolate_template_text(text)
      rendered_text = text.to_s.dup
      variables.each do |key, value|
        rendered_text = rendered_text.gsub("%<#{key}>s", value.to_s)
        rendered_text = rendered_text.gsub("%{#{key}}", value.to_s)
      end
      rendered_text
    end
  end
end
