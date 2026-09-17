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
  class CreateGroup < CreateResourceTool
    default_title "Create group"
    default_description "Create a new user group, optionally with initial members. " \
                        "Groups can be added to projects as members so that all their users share the same roles."

    name "create_group"
    annotations read_only: false, idempotent: false, destructive: false
    model Group

    data_input_schema "JSON representation of the group to be created, in the format accepted by APIv3: " \
                      "'name' and optionally '_links.members', an array of user links such as { \"href\": \"/api/v3/users/1\" }."
  end
end
