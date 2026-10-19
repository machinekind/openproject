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

RSpec.describe OpenProject::Machinekind::Brand do
  describe "color theme registration" do
    let(:themes) { OpenProject::CustomStyles::ColorThemes.themes }

    it "lists the Machinekind theme first" do
      expect(themes.first).to eq(described_class.theme)
    end

    it "keeps the upstream themes" do
      expect(themes.pluck(:theme))
        .to include(OpenProject::CustomStyles::ColorThemes::DEFAULT_THEME_NAME, "OpenProject Gray", "OpenProject Navy Blue")
    end

    it "defines every customizable color" do
      expect(described_class::COLORS.keys).to match_array(OpenProject::CustomStyles::Design.customizable_variables)
    end
  end

  describe "icons" do
    it "uses the Machinekind favicon and touch icon" do
      expect(OpenProject::CustomStyles::Design.favicon_asset_path).to eq("machinekind/favicon.ico")
      expect(OpenProject::CustomStyles::Design.apple_touch_icon_asset_path).to eq("machinekind/apple-touch-icon.png")
    end

    context "with development highlighting" do
      before do
        allow(OpenProject::Configuration).to receive(:development_highlight_enabled?).and_return(true)
      end

      it "keeps the development icons" do
        expect(OpenProject::CustomStyles::Design.favicon_asset_path).to eq("development/favicon.ico")
        expect(OpenProject::CustomStyles::Design.apple_touch_icon_asset_path)
          .to eq("development/apple-touch-icon-120x120.png")
      end
    end
  end

  describe "parity with the compiled stylesheet" do
    let(:stylesheet_dir) { Rails.root.join("frontend/src/global_styles/machinekind") }
    let(:tokens) { stylesheet_dir.join("_tokens.scss").read.scan(/--mk-([a-z0-9-]+): (#[0-9A-F]{6});/).to_h }
    let(:theme_scss) { stylesheet_dir.join("_theme.scss").read }
    let(:token_for_variable) do
      {
        "primary-button-color" => "ink",
        "accent-color" => "red",
        "header-bg-color" => "ink",
        "main-menu-bg-color" => "paper",
        "main-menu-bg-selected-background" => "red"
      }
    end

    it "uses the stylesheet token behind every theme color" do
      token_for_variable.each do |variable, token|
        expect(theme_scss).to include("--#{variable}: var(--mk-#{token});")
        expect(described_class::COLORS.fetch(variable)).to eq(tokens.fetch(token))
      end
    end

    it "uses the header color as the web app manifest theme color" do
      manifest = JSON.parse(Rails.public_path.join("manifest.webmanifest").read)

      expect(manifest.fetch("theme_color")).to eq(described_class::COLORS.fetch("header-bg-color"))
    end
  end

  describe "vendored SVG files" do
    let(:svg_paths) { Rails.root.glob("app/assets/images/machinekind/*.svg") }
    let(:allowed_elements) { %w[svg title g path rect] }
    let(:allowed_attributes) { %w[viewBox role aria-labelledby id fill fill-rule transform d width height x y stroke] }

    it "ships the seven brand SVG files" do
      expect(svg_paths.map { |path| path.basename.to_s }).to contain_exactly(
        "favicon.svg", "lockup-poziomy-ink.svg", "lockup-poziomy-red.svg", "lockup-poziomy-white.svg",
        "mark-ink.svg", "mark-red.svg", "mark-white.svg"
      )
    end

    it "contains only plain vector markup" do
      svg_paths.each do |path|
        document = Nokogiri::XML(path.read, &:strict)

        expect(document.internal_subset).to be_nil, "#{path.basename} declares a DOCTYPE"
        expect(document.xpath("//processing-instruction()")).to be_empty, "#{path.basename} has a processing instruction"
        expect(document.xpath("//*").map(&:name) - allowed_elements).to be_empty, "#{path.basename} has unexpected elements"
        expect(document.xpath("//@*").map(&:name) - allowed_attributes).to be_empty, "#{path.basename} has unexpected attributes"
      end
    end
  end
end
