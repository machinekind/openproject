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
  class SearchBoards < SearchTool
    include BoardAuthorization

    default_title "Search boards"
    default_description "Search work package boards matching all of the passed input parameters. " \
                        "Parameters not passed are ignored. Each result carries the board type and its " \
                        "persisted filters in 'options', and its lists in 'widgets', where every widget " \
                        "names the query it renders and the filters that query was built with. " \
                        "Boards created by other modules are included, notably the backlogs sprint task board. " \
                        "Results are limited to a maximum of #{page_size} boards. To get the rest of the results, " \
                        "call the tool again with a page number of 2 or higher."

    name "search_boards"
    annotations read_only: true, idempotent: true, destructive: false
    enable_pagination

    filter :id
    filter :project_id
    filter :name, filter_proc: ->(boards, value) {
      boards.where("grids.name ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(value)}%")
    }

    input_schema(
      additionalProperties: false,
      properties: {
        id: { type: "number", description: "ID of the board." },
        project_id: { type: "number", description: "ID of the project the board belongs to." },
        name: { type: "string", description: "Name of the board. Accepts partial names, not case-sensitive." }
      }
    )

    def base_scope
      Success(visible_boards.includes(:project, :widgets).order(:id))
    end

    def format_item(item)
      API::V3::Grids::GridRepresenter.create(item, current_user:)
    end
  end
end
