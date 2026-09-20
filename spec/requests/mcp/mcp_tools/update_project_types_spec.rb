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

RSpec.describe McpTools::UpdateProjectTypes do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:user, member_with_permissions: { project => permissions }) }
  let(:permissions) { %i[view_work_packages manage_types] }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "update_project_types",
        arguments: call_args
      }
    }
  end
  let(:call_args) { { project_id: project.id, add: [epic.id] } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:enabled_type) { create(:type, name: "Task") }
  let(:epic) { create(:type, name: "Epic") }
  let(:risk) { create(:type, name: "Risk") }
  let(:project) { create(:project, types: [enabled_type]) }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  before do
    server_config.save!
    tool_config.save!

    project
    access_token
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    describe "adding types" do
      it "enables the type with its base variant" do
        expect { mcp_request }.to change { project.reload.enabled_types.count }.from(1).to(2)

        expect(ProjectType.find_by(project_id: project.id, type_id: epic.id).variant)
          .to eq(epic.default_variant)
      end

      it "responds with the resulting types" do
        mcp_request

        expect(result_item.dig("_embedded", "elements").pluck("name")).to contain_exactly("Task", "Epic")
      end

      context "with several types" do
        let(:call_args) { { project_id: project.id, add: [epic.id, risk.id] } }

        it "enables all of them" do
          expect { mcp_request }.to change { project.reload.enabled_types.count }.from(1).to(3)
        end
      end

      context "when the type is already enabled" do
        let(:call_args) { { project_id: project.id, add: [enabled_type.id] } }

        it "succeeds and changes nothing" do
          expect { mcp_request }.not_to change(ProjectType, :count)

          expect(result_item.dig("_embedded", "elements").pluck("name")).to eq(["Task"])
        end
      end

      context "when the project already uses a named variant of the type" do
        let(:variant) { create(:type_variant, type: epic) }

        before do
          project.project_types.create!(type: epic, variant:)
        end

        it "responds with an error" do
          expect { mcp_request }.not_to change(ProjectType, :count)

          expect(result_item.fetch("error")).to include("Cannot assign a variant and its parent")
        end
      end
    end

    describe "removing types" do
      let(:call_args) { { project_id: project.id, remove: [enabled_type.id] } }

      it "disables the type" do
        expect { mcp_request }.to change(ProjectType, :count).from(1).to(0)
      end

      context "when the type is enabled through a named variant" do
        let(:variant) { create(:type_variant, type: epic) }
        let(:call_args) { { project_id: project.id, remove: [epic.id] } }

        before do
          project.project_types.create!(type: epic, variant:)
        end

        it "disables the type" do
          expect { mcp_request }.to change(ProjectType, :count).from(2).to(1)
        end
      end

      context "when the type is already disabled" do
        let(:call_args) { { project_id: project.id, remove: [risk.id] } }

        it "succeeds and changes nothing" do
          expect { mcp_request }.not_to change(ProjectType, :count)

          expect(result_item.dig("_embedded", "elements").pluck("name")).to eq(["Task"])
        end
      end

      context "when work packages still use the type" do
        before do
          create(:work_package, project:, type: enabled_type)
        end

        it "responds with an error and changes nothing" do
          expect { mcp_request }.not_to change(ProjectType, :count)

          expect(result_item.fetch("error")).to include("still in use by work packages: Task")
        end
      end
    end

    describe "adding and removing in one call" do
      let(:call_args) { { project_id: project.id, add: [epic.id], remove: [enabled_type.id] } }

      it "applies both" do
        mcp_request

        expect(project.reload.enabled_types).to contain_exactly(epic)
      end
    end

    describe "all-or-nothing" do
      context "when one of the added types does not exist" do
        let(:call_args) { { project_id: project.id, add: [epic.id, epic.id + 100] } }

        it "enables none of them" do
          expect { mcp_request }.not_to change(ProjectType, :count)

          expect(result_item.fetch("error")).to eq("The given type could not be found.")
        end
      end

      context "when one of the added types conflicts with an applied variant" do
        let(:variant) { create(:type_variant, type: risk) }

        let(:call_args) { { project_id: project.id, add: [epic.id, risk.id] } }

        before do
          project.project_types.create!(type: risk, variant:)
        end

        it "enables none of them" do
          expect { mcp_request }.not_to change(ProjectType, :count)
        end
      end
    end

    describe "invalid input" do
      context "when neither add nor remove is given" do
        let(:call_args) { { project_id: project.id } }

        it "responds with an error" do
          mcp_request

          expect(result_item.fetch("error")).to eq("Pass at least one type to add or remove.")
        end
      end

      context "when the same type is added and removed" do
        let(:call_args) { { project_id: project.id, add: [epic.id], remove: [epic.id] } }

        it "responds with an error" do
          mcp_request

          expect(result_item.fetch("error")).to eq("A type cannot be added and removed in the same call.")
        end
      end

      context "when add is not an array" do
        let(:call_args) { { project_id: project.id, add: nil } }

        it_behaves_like "MCP tool execution error response"

        it "reports the schema violation" do
          mcp_request

          expect(parsed_results.dig("content", 0, "text")).to include("is not an array")
        end
      end

      context "when the project does not exist" do
        let(:call_args) { { project_id: project.id + 100, add: [epic.id] } }

        it "responds with an error" do
          mcp_request

          expect(result_item.fetch("error")).to eq("The given project could not be found.")
        end
      end
    end

    describe "permissions" do
      context "when the user is an admin without membership" do
        let(:user) { create(:admin) }

        it "enables the type" do
          expect { mcp_request }.to change { project.reload.enabled_types.count }.from(1).to(2)
        end
      end

      context "when the user may not manage types" do
        let(:permissions) { %i[view_work_packages] }

        it "responds with an error and changes nothing" do
          expect { mcp_request }.not_to change(ProjectType, :count)

          expect(result_item.fetch("error"))
            .to eq("You are not allowed to manage the work package types of this project.")
        end
      end

      context "when the user is no member of the project" do
        let(:user) { create(:user) }

        it "responds with an error" do
          mcp_request

          expect(result_item.fetch("error")).to eq("The given project could not be found.")
        end
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
