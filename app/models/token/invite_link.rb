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

module Token
  class InviteLink < Base
    include ExpirableToken

    prefix :join

    store_attribute :data, :project_id, :integer
    store_attribute :data, :role_id, :integer

    def self.validity_time
      24.hours
    end

    class << self
      def active
        not_expired
      end

      def global
        where("data->>'project_id' IS NULL")
      end

      def for_project(project)
        in_scope_of(project.id)
      end

      def in_scope_of(project_id)
        return global if project_id.blank?

        where("data->>'project_id' = ?", project_id.to_s)
      end
    end

    def project
      return @project if defined?(@project)

      @project = Project.find_by(id: project_id)
    end

    def role
      return @role if defined?(@role)

      @role = ProjectRole.find_by(id: role_id)
    end

    def global?
      project_id.blank?
    end

    protected

    def single_value?
      false
    end

    # A scope has at most one usable link: minting a new one revokes the others.
    def delete_previous_token
      scope = self.class.not_expired.in_scope_of(project_id)
      scope = scope.where.not(id:) if persisted?
      scope.delete_all
    end
  end
end
