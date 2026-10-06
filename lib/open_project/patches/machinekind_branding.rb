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

module OpenProject::Patches::Machinekind
  module ColorThemesPatch
    def themes
      [OpenProject::Machinekind::Brand.theme, *super]
    end
  end

  module DesignPatch
    def favicon_asset_path
      return super if OpenProject::Configuration.development_highlight_enabled?

      OpenProject::Machinekind::Brand::FAVICON_ASSET_PATH
    end

    def apple_touch_icon_asset_path
      return super if OpenProject::Configuration.development_highlight_enabled?

      OpenProject::Machinekind::Brand::APPLE_TOUCH_ICON_ASSET_PATH
    end
  end

  module UpdateDesignServicePatch
    private

    # The Machinekind colors ship as compiled CSS defaults, so selecting the theme only removes overrides.
    def set_colors
      return super unless params[:theme] == OpenProject::Machinekind::Brand::THEME_NAME

      DesignColor.destroy_all
    end
  end
end

OpenProject::CustomStyles::ColorThemes.singleton_class.prepend(OpenProject::Patches::Machinekind::ColorThemesPatch)
OpenProject::CustomStyles::Design.singleton_class.prepend(OpenProject::Patches::Machinekind::DesignPatch)
Design::UpdateDesignService.prepend(OpenProject::Patches::Machinekind::UpdateDesignServicePatch)
