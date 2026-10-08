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

RSpec.describe CustomStylesController do
  let(:png_upload) do
    Rack::Test::UploadedFile.new(Rails.root.join("spec/support/custom_styles/logos/logo_image.png"), "image/png")
  end
  let(:html_upload) do
    html = StringIO.new("<html><script>alert(1)</script></html>")
    Rack::Test::UploadedFile.new(html, "image/png", original_filename: "logo.png")
  end

  before do
    login_as user
  end

  context "with admin" do
    let(:user) { build(:admin) }
    let(:invalid_message) { I18n.t("activerecord.errors.messages.invalid") }

    render_views

    describe "#update with image uploads" do
      let(:custom_style) { create(:custom_style) }

      before do
        allow(CustomStyle).to receive(:current).and_return(custom_style)
      end

      it "accepts a PNG logo" do
        post :update, params: { custom_style: { logo: png_upload } }

        expect(response).to redirect_to(action: :show)
        expect(custom_style.reload.logo).to be_present
      end

      it "rejects an HTML document uploaded as the logo and re-renders the branding tab" do
        post :update, params: { tab: "branding", custom_style: { logo: html_upload } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("#{I18n.t(:label_custom_logo)} #{invalid_message}")
        expect(custom_style.reload.logo).not_to be_present
      end

      it "does not show the rejection again on the next page" do
        post :update, params: { tab: "branding", custom_style: { logo: html_upload } }
        # ActionController::TestCase keeps the multipart Content-Type for the next request
        request.delete_header("CONTENT_TYPE")
        get :show, params: { tab: "branding" }

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("#{I18n.t(:label_custom_logo)} #{invalid_message}")
      end

      it "rejects an image above the size limit and re-renders the branding tab" do
        allow(controller).to receive(:image_file_size).and_return(6.megabytes)

        post :update, params: { tab: "branding", custom_style: { favicon: png_upload } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("#{I18n.t(:label_custom_favicon)} is too large")
        expect(custom_style.reload.favicon).not_to be_present
      end
    end

    describe "#create with an image upload" do
      it "rejects an HTML document uploaded as the touch icon and re-renders the branding tab" do
        post :create, params: { tab: "branding", custom_style: { touch_icon: html_upload } }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("#{I18n.t(:label_custom_touch_icon)} #{invalid_message}")
        expect(CustomStyle.count).to eq(0)
      end
    end
  end

  context "for a regular user" do
    let(:user) { build(:user) }

    it "forbids creating a custom style" do
      post :create, params: { custom_style: { logo: png_upload } }

      expect(response).to have_http_status(:forbidden)
      expect(CustomStyle.count).to eq(0)
    end

    it "forbids changing colors" do
      post :update_colors, params: { design_colors: [{ "primary-button-color" => "#990000" }] }

      expect(response).to have_http_status(:forbidden)
      expect(DesignColor.count).to eq(0)
    end

    it "forbids selecting a theme" do
      post :update_themes, params: { theme: "OpenProject Gray" }

      expect(response).to have_http_status(:forbidden)
      expect(CustomStyle.count).to eq(0)
    end

    it "forbids deleting the logo" do
      custom_style = create(:custom_style_with_logo)

      delete :logo_delete

      expect(response).to have_http_status(:forbidden)
      expect(custom_style.reload.logo).to be_present
    end
  end

  context "for an anonymous user" do
    let(:user) { User.anonymous }

    describe "downloading uploaded SVG files" do
      let(:svg_path) { Rails.root.join("spec/fixtures/files/icon_logo.svg") }
      let(:custom_style) do
        create(:custom_style,
               logo: Rack::Test::UploadedFile.new(svg_path, "image/svg+xml"),
               favicon: Rack::Test::UploadedFile.new(svg_path, "image/svg+xml"))
      end

      before do
        allow(CustomStyle).to receive(:current).and_return(custom_style)
      end

      it "sends the logo as an attachment" do
        get :logo_download, params: { digest: custom_style.digest, filename: "icon_logo.svg" }

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Disposition"]).to start_with("attachment")
      end

      it "sends the favicon as an attachment" do
        get :favicon_download, params: { digest: custom_style.digest, filename: "icon_logo.svg" }

        expect(response).to have_http_status(:ok)
        expect(response.headers["Content-Disposition"]).to start_with("attachment")
      end
    end

    describe "#export_logo_download" do
      before do
        allow(CustomStyle).to receive(:current).and_return(build(:custom_style_with_export_logo))
        allow(controller).to receive(:send_file) { controller.head 200 }

        get :export_logo_download, params: { digest: "1234", filename: "export_logo_image.png" }
      end

      it "does not send the file" do
        expect(controller).not_to have_received(:send_file)
        expect(response).not_to be_successful
      end
    end
  end
end
