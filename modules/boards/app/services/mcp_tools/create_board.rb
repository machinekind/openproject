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
  class CreateBoard < Base
    include BoardAuthorization

    SERVICES = {
      "basic" => ::Boards::BasicBoardCreateService,
      "status" => ::Boards::StatusBoardCreateService,
      "assignee" => ::Boards::AssigneeBoardCreateService,
      "version" => ::Boards::VersionBoardCreateService,
      "subproject" => ::Boards::SubprojectBoardCreateService,
      "subtasks" => ::Boards::SubtasksBoardCreateService
    }.freeze

    default_title "Create board"
    default_description "Create a work package board in a project. Requires the Boards module to be enabled there."

    name "create_board"
    annotations read_only: false, idempotent: false, destructive: false

    input_schema(
      additionalProperties: false,
      required: %i[project_id name type],
      properties: {
        project_id: { type: "number", description: "ID of the project the board is created in." },
        name: { type: "string", description: "Name of the board." },
        type: {
          type: "string",
          enum: SERVICES.keys,
          description: "The kind of board to create. 'basic' is a free board with a single unnamed list. " \
                       "'status' starts with a list for the default status and 'version' with one list per open " \
                       "version of the project. 'assignee', 'subproject' and 'subtasks' start without any list, " \
                       "so call create_board_list once per column. 'subtasks' is the parent-child board."
        }
      }
    )

    def call(project_id:, name:, type:)
      project = Project.visible(current_user).find_by(id: project_id)
      return Failure("The given project could not be found.") if project.nil?

      manageable_project(project).bind do
        result = SERVICES.fetch(type).new(user: current_user).call(project:, name:, attribute: type)

        format_board(result)
      end
    end
  end
end
