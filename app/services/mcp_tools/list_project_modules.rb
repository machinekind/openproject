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
  class ListProjectModules < ProjectModulesTool
    default_title "List project modules"
    default_description "Lists the modules available on this OpenProject instance and whether each one is " \
                        "enabled in the given project, e.g. to check whether the Boards module (board_view) is on."

    name "list_project_modules"
    annotations read_only: true, idempotent: true, destructive: false

    input_schema(
      additionalProperties: false,
      required: %i[project_id],
      properties: {
        project_id: {
          type: %w[string number],
          description: "The ID or identifier of the project whose modules shall be listed."
        }
      }
    )

    def call(project_id:)
      project = find_project(project_id)
      return Failure("The given project could not be found.") if project.nil?

      Success(modules_payload(project))
    end
  end
end
