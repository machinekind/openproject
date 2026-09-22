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

require "spec_helper"

RSpec.describe McpTools::ListProjectTypes do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:user, member_with_permissions: { project => permissions }) }
  let(:permissions) { %i[view_work_packages] }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "list_project_types",
        arguments: call_args
      }
    }
  end
  let(:call_args) { { project_id: project.id } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:enabled_type) { create(:type, name: "Epic") }
  let!(:other_type) { create(:type, name: "Risk") }
  let(:project) { create(:project, types: [enabled_type]) }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    it "lists only the types enabled in the project" do
      mcp_request

      expect(result_item.dig("_embedded", "elements").pluck("name")).to eq(["Epic"])
    end

    it "responds with properly formatted types" do
      mcp_request

      expect(result_item.to_json).to match_json_schema.from_docs("types_by_workspace_model")
    end

    context "when the user may only manage types" do
      let(:permissions) { %i[manage_types] }

      it "lists the types" do
        mcp_request

        expect(result_item.dig("_embedded", "elements").pluck("name")).to eq(["Epic"])
      end
    end

    context "when the user is an admin without membership" do
      let(:user) { create(:admin) }

      it "lists the types" do
        mcp_request

        expect(result_item.dig("_embedded", "elements").pluck("name")).to eq(["Epic"])
      end
    end

    context "when the user lacks both permissions in the project" do
      let(:permissions) { [] }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given project could not be found.")
      end
    end

    context "when the user is no member of the project" do
      let(:user) { create(:user) }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given project could not be found.")
      end
    end

    context "when the project is given by its identifier" do
      let(:call_args) { { project_id: project.identifier } }

      it "finds the project" do
        mcp_request

        expect(result_item.dig("_embedded", "elements").pluck("name")).to eq(["Epic"])
      end
    end

    context "when the project does not exist" do
      let(:call_args) { { project_id: project.id + 100 } }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given project could not be found.")
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
