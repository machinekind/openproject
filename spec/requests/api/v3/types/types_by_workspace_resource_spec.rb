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

require "spec_helper"
require "rack/test"

RSpec.describe "/api/v3/projects/:id/types" do
  include Rack::Test::Methods
  include API::V3::Utilities::PathHelper

  let(:role) { create(:project_role, permissions: [:view_work_packages]) }
  let(:requested_project) { project }
  let(:current_user) do
    create(:user, member_with_roles: { project => role })
  end

  let!(:irrelevant_types) { create_list(:type, 4) }
  let!(:expected_types) { create_list(:type, 4) }

  shared_context "for types by workspace" do
    subject(:response) { last_response }

    before do
      expected_types.each { |type| project.project_types.create!(type:) }
    end

    context "for a logged in user" do
      before do
        allow(User).to receive(:current).and_return current_user

        get get_path
      end

      it_behaves_like "API V3 collection response", 4, 4, "Type" do
        let(:elements) { expected_types }
      end

      context "in a foreign project" do
        let(:requested_project) { create(:project, public: false) }

        it_behaves_like "not found"
      end
    end

    context "for not logged in user" do
      before do
        get get_path
      end

      it_behaves_like "not found response based on login_required"
    end
  end

  context "when using the projects route" do
    context "for a project" do
      let(:project) { create(:project, no_types: true) }
      let(:get_path) { api_v3_paths.types_by_project requested_project.id }

      include_context "for types by workspace"
    end

    context "for a portfolio" do
      let(:project) { create(:portfolio, no_types: true) }
      let(:get_path) { api_v3_paths.types_by_project requested_project.id }

      include_context "for types by workspace"
    end
  end

  context "when using the workspaces route" do
    let(:project) { create(:portfolio, no_types: true) }
    let(:get_path) { api_v3_paths.types_by_workspace requested_project.id }

    include_context "for types by workspace"
  end

  describe "#post", content_type: :json do
    let(:project) { create(:project, no_types: true) }
    let(:role) { create(:project_role, permissions: %i[manage_types]) }
    let(:type) { create(:type) }
    let(:post_path) { api_v3_paths.types_by_workspace requested_project.id }
    let(:post_body) { { _links: { type: { href: api_v3_paths.type(type.id) } } }.to_json }
    let(:already_activated_variant) { nil }

    before do
      allow(User).to receive(:current).and_return current_user

      project.project_types.create!(type:, variant: already_activated_variant) if already_activated_variant

      post post_path, post_body
    end

    it "responds with 201 and the activated type" do
      expect(last_response).to have_http_status(201)
      expect(last_response.body).to be_json_eql("Type".to_json).at_path("_type")
      expect(last_response.body).to be_json_eql(type.id.to_json).at_path("id")
    end

    it "activates the type with its base variant" do
      expect(project.reload.enabled_types).to include(type)
      expect(project.project_types.find_by(type_id: type.id).variant).to eq(type.default_variant)
    end

    context "when the type is already activated" do
      let(:already_activated_variant) { type.default_variant }

      it "responds with 200 and adds no second row" do
        expect(last_response).to have_http_status(200)
        expect(ProjectType.where(project_id: project.id, type_id: type.id).count).to eq(1)
      end
    end

    context "when the workspace uses another variant of the type" do
      let(:already_activated_variant) { create(:type_variant, type:) }

      it "responds with 422 and keeps the applied variant" do
        expect(last_response).to have_http_status(422)
        expect(JSON.parse(last_response.body)["errorIdentifier"])
          .to eq("urn:openproject-org:api:v3:errors:PropertyConstraintViolation")
        expect(JSON.parse(last_response.body)["message"])
          .to eq("Types #{I18n.t('activerecord.errors.models.project.attributes.types.cannot_assign_variant_and_parent')}")
        expect(ProjectType.find_by(project_id: project.id, type_id: type.id).variant)
          .to eq(already_activated_variant)
      end
    end

    context "when the request has no body" do
      let(:post_body) { nil }

      it_behaves_like "error response",
                      400,
                      "InvalidRequestBody",
                      I18n.t("api_v3.errors.missing_request_body")
    end

    context "when the type does not exist" do
      let(:post_body) do
        { _links: { type: { href: api_v3_paths.type(not_existing_id(Type)) } } }.to_json
      end

      it_behaves_like "not found"
    end

    context "for a user who may only view work packages" do
      let(:role) { create(:project_role, permissions: %i[view_work_packages]) }

      it_behaves_like "unauthorized access"

      it "still allows reading the types" do
        get api_v3_paths.types_by_workspace(project.id)

        expect(last_response).to have_http_status(200)
      end
    end

    context "in a foreign project" do
      let(:requested_project) { create(:project, public: false) }

      it_behaves_like "not found"
    end
  end

  describe "#delete", content_type: :json do
    let(:project) { create(:project, no_types: true) }
    let(:role) { create(:project_role, permissions: %i[manage_types]) }
    let(:type) { create(:type) }
    let(:variant) { type.default_variant }
    let(:delete_path) { api_v3_paths.type_by_workspace(requested_project.id, type.id) }
    let(:blocking_work_package) { nil }

    before do
      allow(User).to receive(:current).and_return current_user

      project.project_types.create!(type:, variant:)
      blocking_work_package

      delete delete_path
    end

    it "responds with 204 and deactivates the type" do
      expect(last_response).to have_http_status(204)
      expect(ProjectType.where(project_id: project.id, type_id: type.id)).to be_empty
    end

    context "when the type is activated through a named variant" do
      let(:variant) { create(:type_variant, type:) }

      it "responds with 204 and deactivates the type" do
        expect(last_response).to have_http_status(204)
        expect(ProjectType.where(project_id: project.id, type_id: type.id)).to be_empty
      end
    end

    context "when the type is not activated in the workspace" do
      let(:delete_path) { api_v3_paths.type_by_workspace(requested_project.id, irrelevant_types.first.id) }

      it_behaves_like "not found"
    end

    context "when the type does not exist" do
      let(:delete_path) { api_v3_paths.type_by_workspace(requested_project.id, not_existing_id(Type)) }

      it_behaves_like "not found"
    end

    context "when work packages of the type still exist" do
      let(:blocking_work_package) { create(:work_package, project:, type:) }

      it "responds with 422 and keeps the type activated" do
        expect(last_response).to have_http_status(422)
        expect(JSON.parse(last_response.body)["errorIdentifier"])
          .to eq("urn:openproject-org:api:v3:errors:PropertyConstraintViolation")
        expect(JSON.parse(last_response.body)["message"]).to include("still in use by work packages: #{type.name}")
        expect(ProjectType.where(project_id: project.id, type_id: type.id)).to be_present
      end
    end

    context "for a user who may only view work packages" do
      let(:role) { create(:project_role, permissions: %i[view_work_packages]) }

      it_behaves_like "unauthorized access"
    end

    context "in a foreign project" do
      let(:requested_project) { create(:project, public: false) }

      it_behaves_like "not found"
    end
  end
end
