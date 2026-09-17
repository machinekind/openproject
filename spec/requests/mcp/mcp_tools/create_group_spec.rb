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

RSpec.describe McpTools::CreateGroup do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:admin) }
  let(:member) { create(:user) }
  let!(:project) { create(:project) }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "create_group",
        arguments: call_args
      }
    }
  end
  let(:call_args) do
    {
      data: {
        name: "Wojtek team",
        _links: {
          members: [{ href: "/api/v3/users/#{member.id}" }]
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

    it "creates a new group with the given members" do
      expect { mcp_request }.to change(Group, :count).from(0).to(1)

      group = Group.first
      expect(group.name).to eq("Wojtek team")
      expect(group.users).to contain_exactly(member)
    end

    it "responds with a properly formatted group" do
      mcp_request

      expect(result_item.to_json).to match_json_schema.from_docs("group_model")
    end

    context "when the user lacks permission to create groups" do
      let(:user) { create(:user) }

      it "rejects the request without creating a group" do
        expect { mcp_request }.not_to change(Group, :count)
        expect(result_item.fetch("error")).to eq("may not be accessed.")
      end
    end

    context "when the name is missing" do
      let(:call_args) { { data: {} } }

      it "responds with an error" do
        mcp_request
        expect(result_item.fetch("error")).to eq("Name can't be blank.")
      end

      it "does not create a group" do
        expect { mcp_request }.not_to change(Group, :count)
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
