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

RSpec.describe McpTools::UpdateProjectModules do
  subject(:mcp_request) do
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", request_body.to_json
  end

  let(:access_token) { create(:oauth_access_token, scopes: "mcp", resource_owner: user) }
  let(:user) { create(:admin) }
  let(:enabled_module_names) { %w[work_package_tracking] }
  let(:project) { create(:project, enabled_module_names:) }
  let(:call_args) { { project_id: project.id, enable: ["board_view"] } }
  let(:request_body) do
    {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: {
        name: "update_project_modules",
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

    describe "enabling modules" do
      it "enables the module and responds with the resulting state" do
        expect { mcp_request }
          .to change { project.reload.enabled_module_names.sort }
                .from(%w[work_package_tracking])
                .to(%w[board_view work_package_tracking])

        expect(module_entry("board_view")).to include("enabled" => true)
      end

      context "when the module is already enabled" do
        let(:call_args) { { project_id: project.id, enable: ["work_package_tracking"] } }

        it "succeeds and changes nothing" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(module_entry("work_package_tracking")).to include("enabled" => true)
        end
      end

      context "when the module is gated by an enterprise feature" do
        let(:call_args) { { project_id: project.id, enable: ["team_planner_view"] } }

        it "enables it as the settings page does and reports the feature as unavailable" do
          expect { mcp_request }.to change(EnabledModule, :count).by(1)

          expect(project.reload.enabled_module_names).to include("team_planner_view")
          expect(module_entry("team_planner_view"))
            .to include("enabled" => true, "enterpriseFeatureAvailable" => false)
        end
      end

      context "when a dependency is missing" do
        let(:enabled_module_names) { %w[news] }

        it "responds with an error and changes nothing" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error"))
            .to include(I18n.t(:project_module_work_package_tracking), I18n.t(:project_module_board_view))
          expect(project.reload.enabled_module_names).to eq(%w[news])
        end
      end
    end

    describe "disabling modules" do
      let(:enabled_module_names) { %w[work_package_tracking board_view news] }
      let(:call_args) { { project_id: project.id, disable: ["board_view"] } }

      it "disables the module and leaves the others alone" do
        expect { mcp_request }.to change(EnabledModule, :count).by(-1)

        expect(project.reload.enabled_module_names).to contain_exactly("work_package_tracking", "news")
        expect(module_entry("board_view")).to include("enabled" => false)
      end

      context "when the module is not enabled" do
        let(:enabled_module_names) { %w[work_package_tracking] }

        it "succeeds and changes nothing" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(module_entry("board_view")).to include("enabled" => false)
        end
      end

      context "when another enabled module depends on it" do
        let(:call_args) { { project_id: project.id, disable: ["work_package_tracking"] } }

        it "responds with an error and changes nothing" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error"))
            .to include(I18n.t(:project_module_work_package_tracking), I18n.t(:project_module_board_view))
          expect(project.reload.enabled_module_names).to include("work_package_tracking")
        end
      end
    end

    describe "enabling and disabling in one call" do
      let(:enabled_module_names) { %w[work_package_tracking news] }
      let(:call_args) { { project_id: project.id, enable: ["board_view"], disable: ["news"] } }

      it "applies both" do
        mcp_request

        expect(project.reload.enabled_module_names).to contain_exactly("work_package_tracking", "board_view")
      end
    end

    describe "module side effects" do
      let(:enabled_module_names) { %w[work_package_tracking backlogs] }
      let(:call_args) { { project_id: project.id, disable: ["backlogs"] } }

      before do
        project.update!(sprint_sharing: Projects::SprintSettings::SHARE_ALL_PROJECTS)
      end

      it "runs the subscribers the settings page runs" do
        mcp_request

        expect(project.reload.enabled_module_names).not_to include("backlogs")
        expect(project).to be_not_sharing_sprints
      end
    end

    describe "invalid input" do
      context "with an unknown module name" do
        let(:call_args) { { project_id: project.id, enable: ["boards"] } }

        it "responds with an error naming it and the valid names" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error")).to include("Unknown module names: boards.", "board_view")
          expect(result_item.fetch("error")).not_to include("Not available on this instance")
        end
      end

      context "with a module that is registered but not available on this instance" do
        before do
          allow(OpenProject::AccessControl).to(
            receive(:available_project_modules).and_wrap_original { |original, **kw| original.call(**kw) - [:news] }
          )
        end

        let(:call_args) { { project_id: project.id, enable: ["news"] } }

        it "says so rather than calling the name unknown" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error")).to include("Not available on this instance: news.")
          expect(result_item.fetch("error")).not_to include("Unknown module names")
        end
      end

      context "without any delta" do
        let(:call_args) { { project_id: project.id } }

        it "responds with an error and changes nothing" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error")).to eq("Pass at least one module name in 'enable' or 'disable'.")
        end
      end

      context "with empty arrays" do
        let(:call_args) { { project_id: project.id, enable: [], disable: [] } }

        it "responds with an error and changes nothing" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error")).to eq("Pass at least one module name in 'enable' or 'disable'.")
        end
      end

      context "with null instead of an array" do
        let(:call_args) { { project_id: project.id, enable: nil, disable: nil } }

        it "is rejected against the input schema and changes nothing" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(parsed_results.fetch("isError")).to be(true)
          expect(parsed_results.dig("content", 0, "text")).to include("Invalid arguments")
        end
      end

      context "with the same module in both lists" do
        let(:call_args) { { project_id: project.id, enable: ["board_view"], disable: ["board_view"] } }

        it "responds with an error and changes nothing" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error"))
            .to eq("Module names must not appear in both 'enable' and 'disable': board_view.")
        end
      end
    end

    describe "project lookup" do
      context "when the project is given by its identifier" do
        let(:call_args) { { project_id: project.identifier, enable: ["board_view"] } }

        it "finds the project" do
          expect { mcp_request }.to change(EnabledModule, :count).by(1)
        end
      end

      context "when the project does not exist" do
        let(:call_args) { { project_id: project.id + 1000, enable: ["board_view"] } }

        it "responds with an error" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error")).to eq("The given project could not be found.")
        end
      end

      context "when the project is archived" do
        let(:project) { create(:project, :archived, enabled_module_names:) }

        it "responds with an error" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error")).to eq("The given project could not be found.")
        end
      end
    end

    describe "permissions" do
      context "when the user is a member with the permission" do
        let(:user) { create(:user, member_with_permissions: { project => %i[select_project_modules] }) }

        it "enables the module" do
          expect { mcp_request }.to change(EnabledModule, :count).by(1)
        end
      end

      context "when the user is a member without the permission" do
        let(:enabled_module_names) { %w[work_package_tracking news] }
        let(:user) { create(:user, member_with_permissions: { project => %i[view_project] }) }

        it "responds with an error that leaks no module names" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

          expect(result_item.fetch("error")).to eq("You are not allowed to change the modules of this project.")
        end
      end

      context "when the user is not a member of the private project" do
        let(:user) { create(:user) }

        it "responds with an error" do
          expect { mcp_request }.not_to change(EnabledModule, :count)

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
