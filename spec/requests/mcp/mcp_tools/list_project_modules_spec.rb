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

RSpec.describe McpTools::ListProjectModules do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:admin) }
  let(:project) { create(:project, enabled_module_names: %w[work_package_tracking board_view]) }
  let(:call_args) { { project_id: project.id } }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "list_project_modules",
        arguments: call_args
      }
    }
  end
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }
  let(:modules) { result_item.fetch("modules") }
  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!

    project
    access_token
  end

  def module_entry(name)
    modules.find { |mod| mod["name"] == name }
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    it "reports the project and which modules are enabled" do
      mcp_request

      expect(result_item).to include("projectId" => project.id, "projectIdentifier" => project.identifier)
      expect(module_entry("board_view")).to include("enabled" => true, "available" => true)
      expect(module_entry("news")).to include("enabled" => false)
    end

    it "lists every module exactly once" do
      mcp_request

      names = modules.pluck("name")
      expect(names).to eq(names.uniq)
      expect(names).to include("work_package_tracking", "board_view", "news")
    end

    it "labels the modules" do
      mcp_request

      expect(module_entry("board_view")["label"]).to eq(I18n.t(:project_module_board_view))
    end

    it "reports the dependencies of a module" do
      mcp_request

      expect(module_entry("board_view")["dependencies"]).to eq(["work_package_tracking"])
      expect(module_entry("news")["dependencies"]).to eq([])
    end

    it "reports the enterprise feature of a module" do
      mcp_request

      expect(module_entry("team_planner_view")).to include("enterpriseFeature" => "team_planner_view",
                                                           "enterpriseFeatureAvailable" => false)
      expect(module_entry("news")).to include("enterpriseFeature" => nil,
                                              "enterpriseFeatureAvailable" => true)
    end

    context "with an enterprise token", with_ee: %i[team_planner_view] do
      it "reports the enterprise feature as available" do
        mcp_request

        expect(module_entry("team_planner_view")).to include("enterpriseFeature" => "team_planner_view",
                                                             "enterpriseFeatureAvailable" => true)
      end
    end

    context "when an enabled module is not available on the instance" do
      before do
        allow(OpenProject::AccessControl).to(
          receive(:available_project_modules).and_wrap_original { |original, **kw| original.call(**kw) - [:board_view] }
        )
      end

      it "still lists it, but as unavailable" do
        mcp_request

        expect(module_entry("board_view")).to include("enabled" => true, "available" => false)
        expect(modules.pluck("name").count("board_view")).to eq(1)
      end
    end

    context "when the project is given by its identifier" do
      let(:call_args) { { project_id: project.identifier } }

      it "finds the project" do
        mcp_request

        expect(result_item.fetch("projectId")).to eq(project.id)
      end
    end

    context "when the user is a member with the permission" do
      let(:user) { create(:user, member_with_permissions: { project => %i[select_project_modules] }) }

      it "lists the modules" do
        mcp_request

        expect(module_entry("board_view")).to include("enabled" => true)
      end
    end

    context "when the user is a member without the permission" do
      let(:user) { create(:user, member_with_permissions: { project => %i[view_project] }) }

      it "lists the modules, as the project menu shows them" do
        mcp_request

        expect(module_entry("board_view")).to include("enabled" => true)
      end
    end

    context "when the user is not a member of the private project" do
      let(:user) { create(:user) }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given project could not be found.")
      end
    end

    context "when the project does not exist" do
      let(:call_args) { { project_id: project.id + 1000 } }

      it "responds with an error" do
        mcp_request

        expect(result_item.fetch("error")).to eq("The given project could not be found.")
      end
    end

    context "when the project is archived" do
      let(:project) { create(:project, :archived, enabled_module_names: %w[work_package_tracking]) }

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
