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
  module BoardListFilters
    # board-list-container.component.ts matches widget filters on <filterName> and <filterName>_id.
    WIDGET_NAMES = {
      "status" => %w[status_id status],
      "assignee" => %w[assignee assignee_id assigned_to_id],
      "version" => %w[version_id version],
      "subproject" => %w[onlySubproject onlySubproject_id only_subproject_id],
      "subtasks" => %w[parent parent_id]
    }.freeze

    # APIv3 filter names a list of the board is built on, as QueryParamsRepresenter renders them.
    APIV3_NAMES = {
      "status" => %w[status],
      "assignee" => %w[assignee],
      "version" => %w[version targetVersion],
      "subproject" => %w[onlySubproject subprojectId],
      "subtasks" => %w[parent]
    }.freeze

    ACTION_FILTER_ERRORS = {
      "status" => "A status board filters its lists by status; add or remove lists instead.",
      "assignee" => "An assignee board filters its lists by assignee; add or remove lists instead.",
      "version" => "A version board filters its lists by version; add or remove lists instead.",
      "subproject" => "A subproject board filters its lists by subproject; add or remove lists instead.",
      "subtasks" => "A parent-child board filters its lists by parent; add or remove lists instead."
    }.freeze
  end
end
