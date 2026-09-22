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
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

module InviteLinks
  class DialogComponent < ApplicationComponent
    include OpPrimer::ComponentHelpers
    include OpTurbo::Streamable

    DIALOG_ID = "invite-link-dialog"
    FORM_ID = "generate-invite-link-form"

    def initialize(link:, project: nil, error: nil, **options)
      super
      @link = link
      @project = project
      @error = error
    end

    attr_reader :error

    def link_available?
      @link.present?
    end

    def invite_url
      account_join_url(token: @link.value)
    end

    def expires_at
      helpers.format_time(@link.expires_on)
    end

    def form_url
      if @project
        create_invite_link_project_members_path(@project)
      else
        create_invite_link_users_path
      end
    end

    def roles
      @roles ||= ProjectRole.givable.to_a
    end

    def selected_role_id
      @link&.role_id || ProjectRole.in_new_project&.id || roles.first&.id
    end

    def description_key
      @project ? "invite_links.description_project" : "invite_links.description_global"
    end

    def empty_key
      @project ? "invite_links.no_link_project" : "invite_links.no_link_global"
    end
  end
end
