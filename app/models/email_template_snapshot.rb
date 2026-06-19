# frozen_string_literal: true

class EmailTemplateSnapshot < ApplicationRecord
  CHANGE_SOURCES = %w[admin_edit baseline import restored].freeze
  RENDER_RELEVANT_ATTRIBUTES = %w[subject body variables enabled description].freeze

  belongs_to :email_template
  belongs_to :created_by, class_name: 'User', optional: true

  enum :format, { html: 0, text: 1 }

  validates :snapshot_number, presence: true,
                              numericality: { only_integer: true, greater_than: 0 }
  validates :change_source, presence: true, inclusion: { in: CHANGE_SOURCES }
  validates :subject, :body, :description, :locale, presence: true
  validates :snapshot_number, uniqueness: { scope: :email_template_id }

  scope :ordered, -> { order(snapshot_number: :desc) }

  def self.record!(template:, change_source:, actor: nil, before_attributes: nil)
    raise ArgumentError, "Invalid change_source: #{change_source}" unless CHANGE_SOURCES.include?(change_source)

    template.with_lock do
      if template.email_template_snapshots.none? &&
         before_attributes.present? &&
         render_relevant_change_between?(before_attributes, template)
        insert_snapshot!(
          template: template,
          attributes: before_attributes,
          change_source: 'baseline',
          actor: nil
        )
      end

      insert_snapshot!(
        template: template,
        attributes: template.snapshot_content_attributes,
        change_source: change_source,
        actor: actor
      )
    end
  end

  def self.render_relevant_change_between?(before_attrs, template)
    RENDER_RELEVANT_ATTRIBUTES.any? do |attr|
      key = attr.to_sym
      next false unless before_attrs.key?(key)

      before_value = before_attrs[key]
      after_value = template.public_send(attr)
      attr == 'variables' ? before_value.to_h != after_value.to_h : before_value != after_value
    end
  end

  def self.insert_snapshot!(template:, attributes:, change_source:, actor:)
    attrs = attributes.symbolize_keys

    create!(
      email_template: template,
      snapshot_number: (template.email_template_snapshots.maximum(:snapshot_number) || 0) + 1,
      change_source: change_source,
      subject: attrs.fetch(:subject),
      body: attrs.fetch(:body),
      variables: attrs.fetch(:variables, {}),
      format: template.format,
      locale: template.locale,
      enabled: attrs.fetch(:enabled),
      description: attrs.fetch(:description),
      created_by: actor
    )
  end

  private_class_method :insert_snapshot!

  def restorable_attributes
    {
      subject: subject,
      body: body,
      variables: variables,
      enabled: enabled,
      description: description
    }
  end
end
