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
#++

module McpTools
  class UpdateProjectTypes < Base
    include APIV3Helper

    default_title "Update project types"
    default_description "Enables and disables work package types in a project. " \
                        "Use the list_types tool to find type IDs."

    name "update_project_types"
    annotations read_only: false, idempotent: true, destructive: true

    input_schema(
      additionalProperties: false,
      required: %i[project_id],
      properties: {
        project_id: {
          type: "number",
          description: "The ID of the project whose enabled work package types shall be changed."
        },
        add: {
          type: "array",
          items: { type: "number" },
          description: "IDs of work package types to enable in the project. Use the list_types tool to find type IDs."
        },
        remove: {
          type: "array",
          items: { type: "number" },
          description: "IDs of work package types to disable in the project. " \
                       "A type that is still used by work packages in the project cannot be disabled."
        }
      }
    )

    def call(project_id:, add: nil, remove: nil)
      project = ::Project.visible(current_user).find_by(id: project_id)
      return Failure("The given project could not be found.") if project.nil?

      error = change_types(project, Array(add).uniq, Array(remove).uniq)
      return Failure(error) if error

      Success(type_collection(project.reload))
    end

    private

    def change_types(project, add_ids, remove_ids)
      unless current_user.allowed_in_project?(:manage_types, project)
        return "You are not allowed to manage the work package types of this project."
      end

      input_error(add_ids, remove_ids) || apply_all_or_nothing(project, add_ids, remove_ids)
    end

    def input_error(add_ids, remove_ids)
      if add_ids.empty? && remove_ids.empty?
        "Pass at least one type to add or remove."
      elsif add_ids.intersect?(remove_ids)
        "A type cannot be added and removed in the same call."
      end
    end

    # ActiveRecord::Rollback is swallowed by the transaction, which then returns nil, so the
    # failure has to travel out in a local rather than as the block's value.
    def apply_all_or_nothing(project, add_ids, remove_ids)
      error = nil

      Project.transaction do
        error = enable(project, add_ids) || disable(project, remove_ids)
        raise ActiveRecord::Rollback if error
      end

      error
    end

    def enable(project, type_ids)
      type_ids.each do |id|
        type = ::Type.find_by(id:)
        return "The given type could not be found." if type.nil?

        variant = type.default_variant
        return "The given type has no base variant and cannot be enabled." if variant.nil?

        result = ::Projects::Types::AddService.new(user: current_user, model: project).call(variant:)
        return result.message unless result.success?
      end

      nil
    end

    def disable(project, type_ids)
      type_ids.each do |id|
        type = ::Type.find_by(id:)
        return "The given type could not be found." if type.nil?
        next unless project.project_types.exists?(type_id: type.id)

        result = ::Projects::Types::RemoveService
                   .new(user: current_user, model: project)
                   .call(variant: project.type_variant(type))
        return result.message unless result.success?
      end

      nil
    end

    def type_collection(project)
      API::V3::Types::TypeCollectionRepresenter.new(
        project.enabled_types,
        self_link: api_v3_paths.types_by_workspace(project.id),
        current_user:
      )
    end
  end
end
