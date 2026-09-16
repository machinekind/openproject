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
  class CreateUser < CreateResourceTool
    default_title "Create user"
    default_description "Create a new user account. With status 'invited' the user receives an invitation email and " \
                        "sets their own password; with status 'active' a 'password' has to be provided."

    name "create_user"
    annotations read_only: false, idempotent: false, destructive: false
    model User

    data_input_schema "JSON representation of the user to be created, in the format accepted by APIv3: " \
                      "'login', 'email', 'firstName', 'lastName', 'status' ('invited' or 'active'), " \
                      "'language', 'admin', and 'password' for active users."
  end
end
