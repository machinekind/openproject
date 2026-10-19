# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.

module McpTools
  class CreateCustomField < Base
    include ProjectLookup

    default_title "Create custom field"
    default_description "Creates a work package custom field. Administrators only. Use is_for_all together with " \
                        "type_ids for the usual setup. Fields of format hierarchy get their items through the " \
                        "create_custom_field_item tool."

    name "create_custom_field"
    annotations read_only: false, idempotent: false, destructive: false

    input_schema(
      additionalProperties: false,
      required: %i[name field_format],
      properties: {
        name: {
          type: "string",
          description: "The name of the custom field."
        },
        field_format: {
          type: "string",
          description: "The format of the custom field: string, text, int, float, date, bool, list, user, " \
                       "version, link or hierarchy."
        },
        multi_value: {
          type: "boolean",
          description: "Whether several values can be selected. Only possible for list, hierarchy, user and version."
        },
        is_required: {
          type: "boolean",
          description: "Whether work packages must have a value."
        },
        is_for_all: {
          type: "boolean",
          description: "Whether the field is available in all projects. Defaults to false."
        },
        is_filter: {
          type: "boolean",
          description: "Whether the field can be used as a filter. Defaults to true."
        },
        searchable: {
          type: "boolean",
          description: "Whether the field values are included in the work package search."
        },
        default_value: {
          type: "string",
          description: "The default value of the field. For a list field it names one of the possible_values."
        },
        possible_values: {
          type: "array",
          items: { type: "string" },
          description: "The options of a list field, in order. Only allowed for the format list."
        },
        type_ids: {
          type: "array",
          items: { type: "number" },
          description: "IDs of work package types that get the field on their base variant. Use the list_types tool " \
                       "to find type IDs."
        },
        project_ids: {
          type: "array",
          items: { type: %w[string number] },
          description: "IDs or identifiers of the projects in which the field is activated when it is not available " \
                       "in all projects. Projects that merely use one of the type_ids are not activated implicitly."
        }
      }
    )

    def call(name:, field_format:, possible_values: nil, default_value: nil, type_ids: nil, project_ids: nil,
             is_for_all: false, **)
      return Failure("Only administrators can create custom fields.") unless current_user.admin?

      error = input_error(field_format, possible_values, default_value, project_ids, is_for_all)
      return Failure(error) if error

      variants = find_variants(Array(type_ids).uniq)
      return Failure(variants) if variants.is_a?(String)

      projects = find_projects(Array(project_ids).uniq)
      return Failure(projects) if projects.is_a?(String)

      create_field(variants, projects, name:, field_format:, possible_values:, default_value:, is_for_all:, **)
    end

    private

    def input_error(field_format, possible_values, default_value, project_ids, is_for_all)
      available = ::OpenProject::CustomFieldFormat.available_for_class_name("WorkPackage").map(&:name)

      if available.exclude?(field_format)
        "Unknown field format '#{field_format}'. Available formats: #{available.join(', ')}."
      elsif is_for_all && project_ids.present?
        "project_ids cannot be combined with is_for_all; the field is then available in every project."
      elsif field_format == "list"
        list_value_error(possible_values, default_value)
      elsif possible_values
        "possible_values can only be given for the format list."
      end
    end

    def list_value_error(possible_values, default_value)
      if Array(possible_values).empty?
        "possible_values must name at least one option for the format list."
      elsif default_value && possible_values.exclude?(default_value)
        "default_value must be one of possible_values."
      end
    end

    def find_variants(type_ids)
      type_ids.map do |id|
        type = ::Type.find_by(id:)
        return "The given type could not be found." if type.nil?

        variant = type.default_variant
        return "The given type has no base variant and cannot receive the custom field." if variant.nil?

        variant
      end
    end

    def find_projects(project_ids)
      project_ids.map do |id|
        project = find_project(id)
        return "The given project could not be found." if project.nil?

        project
      end
    end

    def create_field(variants, projects, field_format:, possible_values:, default_value:, **attributes)
      result = nil
      error = nil

      CustomField.transaction do
        result = ::CustomFields::CreateService
                   .new(user: current_user)
                   .call(type: "WorkPackageCustomField", field_format:, **defaults, **attributes,
                         **value_attributes(field_format, possible_values, default_value))

        error = result.success? ? attach(result.result, variants, projects) : result.message
        raise ActiveRecord::Rollback if error
      end

      error ? Failure(error) : Success(representer(result.result))
    end

    def defaults
      { is_filter: true }
    end

    def value_attributes(field_format, possible_values, default_value)
      return { default_value: }.compact unless field_format == "list"

      options = possible_values.each_with_index.map do |value, i|
        { value:, position: i + 1, default_value: value == default_value }
      end
      { custom_options_attributes: options }
    end

    def attach(custom_field, variants, projects)
      custom_field.type_variants = variants
      custom_field.projects = projects unless custom_field.is_for_all?
      variants.each { |variant| add_to_customized_form(variant, custom_field) }

      nil
    rescue ActiveRecord::ActiveRecordError => e
      e.message
    end

    # A variant with a saved form configuration only shows the attributes its groups list, and the
    # next form save drops custom fields that are attached but not grouped.
    def add_to_customized_form(variant, custom_field)
      return if variant[:attribute_groups].blank?

      groups = variant.attribute_groups
      groups.reject! { |group| group.key.to_s == "__empty" }
      place_in_groups(groups, variant, custom_field.attribute_name)

      variant.attribute_groups_will_change!
      variant.save!
    end

    def place_in_groups(groups, variant, attribute)
      target = groups.reverse.find { |group| group.group_type == :attribute }

      if target
        target.attributes << attribute
      else
        groups << ::Type::AttributeGroup.new(variant, :other, [attribute])
      end
    end

    def representer(custom_field)
      ::API::V3::CustomFields::CustomFieldRepresenter.create(custom_field.reload, current_user:)
    end
  end
end
