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

require "spec_helper"

RSpec.describe McpTools::CreateMembership do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:admin) }
  let(:project) { create(:project) }
  let(:group) { create(:group) }
  let(:role) { create(:project_role) }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "create_membership",
        arguments: call_args
      }
    }
  end
  let(:call_args) do
    {
      data: {
        _links: {
          principal: { href: "/api/v3/groups/#{group.id}" },
          project: { href: "/api/v3/projects/#{project.id}" },
          roles: [{ href: "/api/v3/roles/#{role.id}" }]
        }
      }
    }
  end
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    it "adds the principal to the project with the given role" do
      expect { mcp_request }.to change(Member, :count).from(0).to(1)

      member = Member.first
      expect(member.principal).to eq(group)
      expect(member.project).to eq(project)
      expect(member.roles).to contain_exactly(role)
    end

    it "responds with a properly formatted membership" do
      mcp_request

      expect(result_item).to include("_type" => "Membership", "id" => Member.first.id)
    end

    context "when no role is given" do
      let(:call_args) do
        {
          data: {
            _links: {
              principal: { href: "/api/v3/groups/#{group.id}" },
              project: { href: "/api/v3/projects/#{project.id}" }
            }
          }
        }
      end

      it "responds with an error" do
        mcp_request
        expect(result_item.fetch("error")).to include("Roles")
      end

      it "does not create a membership" do
        expect { mcp_request }.not_to change(Member, :count)
      end
    end
  end

  context "when the MCP server is disabled" do
    let(:server_config) { create(:mcp_configuration, identifier: "mcp_server", enabled: false) }

    it "responds with a 404" do
      mcp_request
      expect(last_response).to have_http_status(404)
    end
  end
end
