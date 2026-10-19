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

require "spec_helper"

RSpec.describe McpTools::CreateCustomField do
  subject(:mcp_request) { post_tool(described_class.name, call_args) }

  let(:access_token) do
    create(:oauth_access_token, scopes: "mcp", resource_owner: user, application: create(:oauth_application, owner: nil))
  end
  let(:user) { create(:admin) }
  let(:call_args) { { name: "Region", field_format: "hierarchy", is_for_all: true, multi_value: true, type_ids: [type.id] } }
  let(:parsed_results) { JSON.parse(last_response.body).fetch("result") }
  let(:result_item) { parsed_results.fetch("structuredContent") }

  let(:type) { create(:type, name: "Task") }
  let(:project) { create(:project, types: [type]) }

  let(:server_config) { create(:mcp_configuration, identifier: "mcp_server") }
  let(:tool_config) { create(:mcp_configuration, identifier: described_class.qualified_name) }

  def post_tool(tool_name, arguments)
    header "Authorization", "Bearer #{access_token.plaintext_token}"
    header "Content-Type", "application/json"
    post "/mcp", {
      jsonrpc: "2.0",
      id: "Test-Request",
      method: "tools/call",
      params: { name: tool_name, arguments: }
    }.to_json
  end

  before do
    server_config.save!
    tool_config.save!
    project
    access_token
  end

  context "when the MCP server is enabled" do
    it_behaves_like "MCP text tool"

    describe "creating a hierarchy field" do
      let(:custom_field) { WorkPackageCustomField.find_by!(name: "Region") }

      before { mcp_request }

      it "creates the field with a root item" do
        expect(custom_field.field_format).to eq("hierarchy")
        expect(custom_field).to be_multi_value
        expect(custom_field).to be_is_for_all
        expect(custom_field.hierarchy_root).to be_present
      end

      it "attaches the base variant of the type" do
        expect(custom_field.type_variants).to contain_exactly(type.default_variant)
      end

      it "responds with the custom field" do
        expect(result_item).to include("name" => "Region", "id" => custom_field.id)
      end
    end

    describe "creating a list field" do
      let(:call_args) { { name: "Severity", field_format: "list", possible_values: %w[Low Medium High] } }
      let(:custom_field) { WorkPackageCustomField.find_by!(name: "Severity") }

      it "creates the options in order without a default" do
        mcp_request

        expect(custom_field.custom_options.order(:position).pluck(:value)).to eq(%w[Low Medium High])
        expect(custom_field.default_value).to be_nil
      end

      context "with a default_value" do
        let(:call_args) { super().merge(default_value: "Medium") }

        it "marks that option as the default" do
          mcp_request

          expect(custom_field.default_value).to eq(custom_field.custom_options.find_by!(value: "Medium").id.to_s)
        end
      end

      context "with a default_value that is not an option" do
        let(:call_args) { super().merge(default_value: "Critical") }

        it "responds with an error and creates nothing" do
          expect { mcp_request }.not_to change(CustomField, :count)

          expect(result_item.fetch("error")).to eq("default_value must be one of possible_values.")
        end
      end

      context "without possible_values" do
        let(:call_args) { { name: "Severity", field_format: "list" } }

        it "responds with an error and creates nothing" do
          expect { mcp_request }.not_to change(CustomField, :count)

          expect(result_item.fetch("error")).to eq("possible_values must name at least one option for the format list.")
        end
      end
    end

    context "when the format rejects the attributes" do
      let(:call_args) { { name: "Region", field_format: "string", multi_value: true } }

      it "responds with the validation error and creates nothing" do
        expect { mcp_request }.not_to change(CustomField, :count)

        expect(result_item.fetch("error")).to include("must be blank")
      end
    end

    context "when combining is_for_all with project_ids" do
      let(:call_args) { { name: "Region", field_format: "string", is_for_all: true, project_ids: [project.id] } }

      it "responds with an error and creates nothing" do
        expect { mcp_request }.not_to change(CustomField, :count)

        expect(result_item.fetch("error")).to start_with("project_ids cannot be combined with is_for_all")
      end
    end

    context "when the type has a customized form configuration" do
      let(:type) { create(:type, name: "Task", attribute_groups: [["details", %i[subject status]]]) }
      let(:custom_field) { WorkPackageCustomField.find_by!(name: "Region") }

      it "adds the field to the last attribute group of the base variant" do
        mcp_request

        groups = type.default_variant.reload.attribute_groups
        expect(groups.last.attributes.map(&:to_s)).to eq(["subject", "status", "custom_field_#{custom_field.id}"])
        expect(custom_field.type_variants).to contain_exactly(type.default_variant)
      end

      context "when the form has no attribute group left" do
        let(:type) { create(:type, name: "Task", attribute_groups: [["__empty", []]]) }

        it "replaces the placeholder with a group holding the field" do
          mcp_request

          groups = type.default_variant.reload.attribute_groups
          expect(groups.map { |group| group.key.to_s }).to eq(["other"])
          expect(groups.first.attributes.map(&:to_s)).to eq(["custom_field_#{custom_field.id}"])
        end
      end

      context "when saving the form fails" do
        before do
          allow_any_instance_of(TypeVariant) # rubocop:disable RSpec/AnyInstance
            .to receive(:save!).and_raise(ActiveRecord::RecordInvalid)
        end

        it "rolls back the field and its root item" do
          expect { mcp_request }
            .to not_change(CustomField, :count)
            .and not_change(CustomField::Hierarchy::Item, :count)

          expect(result_item.fetch("error")).to be_present
        end
      end
    end

    context "when passing possible_values for another format" do
      let(:call_args) { { name: "Region", field_format: "string", possible_values: %w[a] } }

      it "responds with an error and creates nothing" do
        expect { mcp_request }.not_to change(CustomField, :count)

        expect(result_item.fetch("error")).to eq("possible_values can only be given for the format list.")
      end
    end

    context "when giving project_ids without is_for_all" do
      let(:call_args) { { name: "Region", field_format: "string", project_ids: [project.id] } }

      it "activates the field in the project" do
        mcp_request

        expect(WorkPackageCustomField.find_by!(name: "Region").projects).to contain_exactly(project)
      end
    end

    context "when giving type_ids without is_for_all" do
      let(:call_args) { { name: "Region", field_format: "string", type_ids: [type.id], project_ids: [project.id] } }
      let!(:other_project) { create(:project, types: [type]) }

      it "activates the field only in the given projects" do
        mcp_request

        custom_field = WorkPackageCustomField.find_by!(name: "Region")
        expect(project.reload.work_package_custom_field_ids).to include(custom_field.id)
        expect(other_project.reload.work_package_custom_field_ids).not_to include(custom_field.id)
      end
    end

    context "when the format is unknown" do
      let(:call_args) { { name: "Region", field_format: "bogus" } }

      it "responds with an error listing the available formats" do
        expect { mcp_request }.not_to change(CustomField, :count)

        expect(result_item.fetch("error")).to start_with("Unknown field format 'bogus'. Available formats: ")
        expect(result_item.fetch("error")).to include("hierarchy")
      end
    end

    context "when a type does not exist" do
      let(:call_args) { { name: "Region", field_format: "string", type_ids: [type.id + 100] } }

      it "responds with an error and creates nothing" do
        expect { mcp_request }.not_to change(CustomField, :count)

        expect(result_item.fetch("error")).to eq("The given type could not be found.")
      end
    end

    context "when a project does not exist" do
      let(:call_args) { { name: "Region", field_format: "string", project_ids: [project.id + 100] } }

      it "responds with an error and creates nothing" do
        expect { mcp_request }.not_to change(CustomField, :count)

        expect(result_item.fetch("error")).to eq("The given project could not be found.")
      end
    end

    context "when the user is not an administrator" do
      let(:user) { create(:user) }

      it "responds with an error and creates nothing" do
        expect { mcp_request }.not_to change(CustomField, :count)

        expect(result_item.fetch("error")).to eq("Only administrators can create custom fields.")
      end
    end

    describe "setting the new field on a work package" do
      let(:work_package) { create(:work_package, project:, type:) }

      before do
        create(:mcp_configuration, identifier: McpTools::CreateCustomFieldItem.qualified_name)
        create(:mcp_configuration, identifier: McpTools::UpdateWorkPackage.qualified_name)
      end

      it "stores the hierarchy item as value" do
        mcp_request
        custom_field = WorkPackageCustomField.find_by!(name: "Region")

        post_tool("create_custom_field_item", { custom_field_id: custom_field.id, label: "Europe" })
        item_id = JSON.parse(last_response.body).dig("result", "structuredContent", "id")

        post_tool("update_work_package",
                  id: work_package.id,
                  data: {
                    lockVersion: work_package.lock_version,
                    _links: { "customField#{custom_field.id}": [{ href: "/api/v3/custom_field_items/#{item_id}" }] }
                  })

        expect(work_package.reload.public_send(:"custom_field_#{custom_field.id}").map(&:id)).to eq([item_id])
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
