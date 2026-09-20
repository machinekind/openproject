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
  class UpdateProjectModules < ProjectModulesTool
    default_title "Update project modules"
    default_description "Enables or disables modules in a project, e.g. board_view for Boards, backlogs or costs. " \
                        "Use list_project_modules to obtain the valid module names."

    name "update_project_modules"
    annotations read_only: false, idempotent: true, destructive: true

    input_schema(
      additionalProperties: false,
      required: %i[project_id],
      properties: {
        project_id: {
          type: %w[string number],
          description: "The ID or identifier of the project whose modules shall be changed."
        },
        enable: {
          type: "array",
          items: { type: "string" },
          description: "Names of modules to enable, e.g. 'board_view'. Use list_project_modules to obtain valid " \
                       "names. Modules that are already enabled are left untouched. Dependencies are not enabled " \
                       "automatically; enable them in the same call."
        },
        disable: {
          type: "array",
          items: { type: "string" },
          description: "Names of modules to disable. Modules that are not enabled are ignored. Disabling a module " \
                       "that another enabled module depends on is rejected."
        }
      }
    )

    def call(project_id:, enable: nil, disable: nil)
      project = find_project(project_id)
      return Failure("The given project could not be found.") if project.nil?

      unless current_user.allowed_in_project?(:select_project_modules, project)
        return Failure("You are not allowed to change the modules of this project.")
      end

      to_enable = Array(enable).map(&:to_s)
      to_disable = Array(disable).map(&:to_s)

      validate_delta(project, to_enable, to_disable)
        .bind { apply(project, to_enable, to_disable) }
    end

    private

    def validate_delta(project, to_enable, to_disable)
      if to_enable.empty? && to_disable.empty?
        return Failure("Pass at least one module name in 'enable' or 'disable'.")
      end

      both = to_enable & to_disable
      if both.any?
        return Failure("Module names must not appear in both 'enable' and 'disable': #{both.join(', ')}.")
      end

      unassignable = (to_enable + to_disable) - assignable_module_names(project)
      return Success(project) if unassignable.none?

      Failure(unassignable_message(project, unassignable))
    end

    def unassignable_message(project, unassignable)
      unavailable, unknown = unassignable.partition { |name| registered_module_names.include?(name) }

      message = []
      message << "Not available on this instance: #{unavailable.join(', ')}." if unavailable.any?
      message << "Unknown module names: #{unknown.join(', ')}." if unknown.any?
      message << "Valid module names: #{assignable_module_names(project).sort.join(', ')}."

      message.join(" ")
    end

    def registered_module_names
      OpenProject::AccessControl.modules.map { |mod| mod[:name].to_s }
    end

    def apply(project, to_enable, to_disable)
      names = (project.enabled_module_names | to_enable) - to_disable

      result = Projects::EnabledModulesService
                 .new(user: current_user, model: project)
                 .call(enabled_modules: names)

      if result.success?
        Success(modules_payload(result.result))
      else
        Failure(result.message)
      end
    end
  end
end
