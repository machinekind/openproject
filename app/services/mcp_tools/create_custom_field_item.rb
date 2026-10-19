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
  class CreateCustomFieldItem < Base
    default_title "Create custom field item"
    default_description "Adds an item to a hierarchy custom field. Administrators only. Without parent_item_id " \
                        "the item is added at the top level of the field."

    name "create_custom_field_item"
    annotations read_only: false, idempotent: false, destructive: false

    input_schema(
      additionalProperties: false,
      required: %i[custom_field_id label],
      properties: {
        custom_field_id: {
          type: "number",
          description: "The ID of the hierarchy custom field that receives the item."
        },
        label: {
          type: "string",
          description: "The label of the item. Must be unique among the items with the same parent."
        },
        short: {
          type: "string",
          description: "An optional short name of the item. Must be unique among the items with the same parent."
        },
        parent_item_id: {
          type: "number",
          description: "The ID of the item below which the new item is added. Use the search_custom_field_items " \
                       "tool to find item IDs."
        }
      }
    )

    def call(custom_field_id:, label:, short: nil, parent_item_id: nil)
      return Failure("Only administrators can change custom field items.") unless current_user.admin?

      custom_field = ::CustomField.visible(current_user).find_by(id: custom_field_id)
      return Failure("The given custom field could not be found.") if custom_field.nil?
      return Failure("Items can only be added to hierarchy custom fields.") unless custom_field.field_format_hierarchy?

      parent = find_parent(custom_field, parent_item_id)
      return Failure("The given parent item does not belong to this custom field.") if parent.nil?

      insert(parent, label, short)
    end

    private

    def find_parent(custom_field, parent_item_id)
      return custom_field.hierarchy_root if parent_item_id.nil?

      custom_field.hierarchy_root&.self_and_descendants&.find_by(id: parent_item_id)
    end

    def insert(parent, label, short)
      ::CustomFields::Hierarchy::HierarchicalItemService
        .new
        .insert_item(contract_class: ::CustomFields::Hierarchy::InsertListItemContract, parent:, label:, short:)
        .either(
          ->(item) { Success(represent(item)) },
          ->(errors) { Failure(error_sentence(errors)) }
        )
    end

    def represent(item)
      aggregate = API::V3::CustomFields::Hierarchy::HierarchicalItemAggregate.new(item:, depth: item.depth - 1)
      API::V3::CustomFields::Hierarchy::HierarchyItemRepresenter.new(aggregate, current_user:)
    end

    def error_sentence(errors)
      return errors.full_messages.join("; ") if errors.is_a?(ActiveModel::Errors)

      errors.errors.map { |error| "#{error.path.join('.')}: #{error.text}" }.join("; ")
    end
  end
end
