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

module McpTools
  class CreateProject < CreateResourceTool
    default_title "Create project"
    default_description "Create a new project. Requires at least a name. The identifier is derived from the name unless given."

    name "create_project"
    annotations read_only: false, idempotent: false, destructive: false
    model Project

    data_input_schema "JSON representation of the project to be created, in the format accepted by APIv3 " \
                      "(e.g. 'name', 'identifier', 'description', 'public', and '_links.parent')."

    private

    def service_arguments(attributes)
      attributes.merge(workspace_type: "project")
    end
  end
end
