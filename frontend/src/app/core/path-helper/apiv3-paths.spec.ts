//-- copyright
// OpenProject is an open source project management software.
// Copyright (C) the OpenProject GmbH
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License version 3.
//
// OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
// Copyright (C) 2006-2013 Jean-Philippe Lang
// Copyright (C) 2010-2013 the ChiliProject Team
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
//
// See COPYRIGHT and LICENSE files for more details.
//++

import { ApiV3Paths } from 'core-app/core/path-helper/apiv3-paths';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';

describe('ApiV3Paths#principals', () => {
  const paths = new ApiV3Paths('/base');

  const resource = (attributes:Record<string, unknown>) => attributes as unknown as HalResource;

  it('suggests principals mentionable on an existing work package', () => {
    const url = paths.principals(resource({ _type: 'WorkPackage', id: '42' }), 'ad');

    expect(url).toContain('/base/api/v3/principals?');
    expect(decodeURIComponent(url!)).toContain('"mentionable_on_work_package":{"operator":"=","values":["42"]}');
    expect(decodeURIComponent(url!)).toContain('"name":{"operator":"~","values":["ad"]}');
  });

  it('suggests project members for a new work package', () => {
    const url = paths.principals(resource({ _type: 'WorkPackage', id: 'new', project: { id: '7' } }), null);

    expect(decodeURIComponent(url!)).toContain('"member":{"operator":"=","values":["7"]}');
  });

  it('offers no mentions for other resources', () => {
    expect(paths.principals(resource({ _type: 'Post', id: '42' }), 'ad')).toBeNull();
  });
});
