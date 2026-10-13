--!strict
--!native
-- `@merged-lands` over a load order, held to Merged Lands 0.2.0's own output: the plugins in
-- `golden/` are what the original wrote for the plugins `build.luau` makes, `patched` with the
-- `.mergedlands.toml` files in `patches/` beside them. The header's description ends in the time
-- of the run, so it's left out of the comparison, and nothing else is. `jess package test` runs
-- every case from the package's source and from its packed JPK.
local bytes = require '@dream/bytes'
local mergedLands = require '@merged-lands'
local openmw = require '@openmw'
local support = require './support'
local tes3 = require '@tes3'
local test = require '@jess/test'

local expect = test.expect
local suite = test.new()

type Report = {
  output: string?,
  plugins: number,
  lands: number,
  merged: number,
  textures: number,
  seams: number,
  masters: { string },
  activated: boolean,
}

local OutputName = 'Merged Lands.omwaddon'
local Vertices = 65 * 65

-- Where HEDR keeps the description, which ends in the time of the run.
local DescriptionStart, DescriptionLength = 64, 256

--- Merges the load order as its openmw.cfg stands, with `options` as `state.mergedlands`.
local function merge(order: support.Order, options: { [string]: unknown }): Report
  local state: { [string]: unknown } = { mergedlands = options }
  mergedLands(state, openmw.new(order.file))

  -- The tool leaves its report in the options table it was handed.
  expect(state.mergedlands).toBe(options)
  return options.report :: Report
end

--- A report the way the original harness printed one.
local function line(report: Report): string
  return `report: {report.lands} lands, {report.merged} merged, {report.seams} seams, {report.textures} textures, masters {table.concat(report.masters, ' ')}, activated {report.activated}`
end

suite.describe('the fixtures', function()
  suite.it('are the plugins the original read, by the sizes it recorded for its masters', function()
    local order = support.order 'fixtures'

    for _, name in { 'default', 'patched' } do
      local masters = tes3.open(support.golden(name)):masters()
      expect(#masters).toBe(#support.Standard)

      for position, master in masters do
        expect(master.name).toBe(support.Standard[position])
        expect(jess.fs.size(jess.fs.join(order.data, master.name))).toBe(master.size)
      end
    end
  end)
end)

suite.describe('merging', function()
  suite.it('matches the original and enables its plugin', function()
    local order = support.order 'default'
    local output = jess.fs.join(order.out, OutputName)

    local report = merge(order, { activate = true })
    expect(line(report)).toBe 'report: 12 lands, 7 merged, 71 seams, 4 textures, masters Base.esm Hills.esp Valleys.esp, activated true'
    expect(report.output).toBe(output)
    expect(report.plugins).toBe(3)
    support.expectOriginal(output, 'default')

    local ending = `content={OutputName}\n`
    expect(string.sub(assert(jess.fs.read(order.file)), -#ending)).toBe(ending)

    -- The next run leaves its own output out of the merge, and writes the same plugin again.
    local again = merge(order, { activate = true })
    expect(line(again)).toBe 'report: 12 lands, 7 merged, 71 seams, 4 textures, masters Base.esm Hills.esp Valleys.esp, activated false'
    expect(again.plugins).toBe(3)
    support.expectOriginal(output, 'default')
  end)

  suite.it('matches the original with patch files', function()
    local order = support.order('patched', { 'Hills.mergedlands.toml', 'Valleys.mergedlands.toml' })

    local report = merge(order, {})
    expect(line(report)).toBe 'report: 12 lands, 7 merged, 0 seams, 5 textures, masters Base.esm Hills.esp Valleys.esp, activated false'
    support.expectOriginal(jess.fs.join(order.out, OutputName), 'patched')
    expect(string.find(assert(jess.fs.read(order.file)), 'Merged Lands', 1, true)).toBeNil()
  end)

  suite.it('writes elsewhere without enabling what OpenMW cannot load', function()
    local order = support.order 'elsewhere'
    local elsewhere = jess.fs.join(order.root, 'elsewhere')

    local report = merge(order, {
      activate = true,
      outputDir = elsewhere,
      outputFile = 'Terrain.omwaddon',
    })

    expect(report.activated).toBe(false)
    expect(report.output).toBe(jess.fs.join(elsewhere, 'Terrain.omwaddon'))
    expect(jess.fs.isFile(jess.fs.join(elsewhere, 'Terrain.omwaddon'))).toBe(true)
    expect(jess.fs.exists(jess.fs.join(order.out, OutputName))).toBe(false)
    expect(string.find(assert(jess.fs.read(order.file)), 'Terrain', 1, true)).toBeNil()
  end)

  suite.it('writes to the first data folder without data-local', function()
    local order = support.order 'first-data'
    jess.fs.write(order.file, support.configuration(order, support.Standard, false))

    local report = merge(order, {})
    expect(report.output).toBe(jess.fs.join(order.data, OutputName))
    expect(jess.fs.isFile(jess.fs.join(order.data, OutputName))).toBe(true)
    expect(jess.fs.exists(jess.fs.join(order.out, OutputName))).toBe(false)
  end)

  suite.it('stops on a master that loads later', function()
    local order = support.order('order', nil, { 'Hills.esp', 'Base.esm', 'Valleys.esp' })
    local options: { [string]: unknown } = {}

    expect(function() mergedLands({ mergedlands = options }, openmw.new(order.file)) end).toThrow 'Hills.esp declares master Base.esm but loads before it'
    expect(options.report).toBeNil()
    expect(jess.fs.exists(jess.fs.join(order.out, OutputName))).toBe(false)
  end)

  suite.it('needs a Context', function()
    expect(function() mergedLands({}, nil) end).toThrow 'merged-lands needs an OpenMW config'
  end)
end)

-- What the original's goldens don't reach: the content the merge leaves out, and the record
-- flags it reads off a plugin's records.
suite.describe('reading the load order', function()
  suite.it('skips content that has no file, won\'t open, or holds no records', function()
    local content = table.clone(support.Standard)
    table.insert(content, 2, 'Scripts.omwscripts')
    table.insert(content, 'Broken.esp')
    table.insert(content, 'Missing.esp')

    local order = support.order('skipped', nil, content)
    jess.fs.write(jess.fs.join(order.data, 'Scripts.omwscripts'), 'PLAYER: scripts/player.lua\n')
    jess.fs.write(jess.fs.join(order.data, 'Broken.esp'), 'not a plugin')

    local report = merge(order, {})
    expect(report.plugins).toBe(3)
    support.expectOriginal(jess.fs.join(order.out, OutputName), 'default')
  end)

  suite.it('carries a LAND\'s record flags into the plugin', function()
    local order = support.order('flagged', nil, { 'Flagged.esm' })

    -- One vertex at a height of exactly 0, which the original writes a cell for.
    local heights, normals = buffer.create(Vertices * 4), buffer.create(Vertices * 3)
    buffer.writei32(heights, (10 * 65 + 10) * 4, -20)
    for vertex = 0, Vertices - 1 do
      buffer.writei8(normals, vertex * 3 + 2, 120)
    end

    local flagged = tes3.new 'master'
    flagged:insertValue(1, { type = 'Landscape', grid = { 3, -2 }, flags = 'PERSISTENT' })
    tes3.land.write(flagged, 1, {
      flags = 9,
      heightOffset = 20,
      heights = heights,
      normals = normals,
      worldMap = false,
    })

    flagged:updateRecordCount()
    jess.fs.write(jess.fs.join(order.data, 'Flagged.esm'), flagged:save())

    local report = merge(order, {})
    expect(report.lands).toBe(1)
    expect(report.masters).toEqual { 'Flagged.esm' }

    local merged = tes3.open(assert(jess.fs.readBuffer(report.output :: string)))
    expect(merged:count()).toBe(2)
    expect(merged:tag(1)).toBe 'LAND'
    expect(tes3.land.read(merged, 1, {}).grid).toEqual { 3, -2 }
    expect(tes3.records.headerFlags(merged, 1)).toEqual {
      value = 0x400,
      deleted = false,
      persistent = true,
      ignored = false,
      blocked = false,
    }
  end)

  suite.it('stops on a deleted LTEX nothing defined before', function()
    local order = support.order('deleted', nil, { 'Deleted.esp' })
    local deleted = tes3.new()
    deleted:insertValue(1, {
      type = 'LandscapeTexture',
      id = 'Gone',
      index = 0,
      fileName = 'tx_gone.dds',
      flags = 'DELETED',
    })

    deleted:updateRecordCount()
    jess.fs.write(jess.fs.join(order.data, 'Deleted.esp'), deleted:save())

    expect(function() merge(order, {}) end).toThrow 'merged-lands: Deleted.esp adds the deleted LTEX Gone, as the original won\'t'
    expect(jess.fs.exists(jess.fs.join(order.out, OutputName))).toBe(false)
  end)
end)

-- Which plugins a merge takes, and in what order: the paths merged_lands.toml or the options
-- leave out, and the plugins the options name.
suite.describe('choosing what to merge', function()
  suite.it('leaves out a plugin merged_lands.toml ignores by its path, whatever its case', function()
    local order = support.order 'ignored-path'

    -- A folder under the plugin, a folder beside the data folder, one relative to openmw.cfg's
    -- folder, and then the plugin itself, in upper case.
    local ignoredPaths = {
      jess.fs.join(order.data, 'Valleys.esp/deeper/than/the/plugin'),
      jess.fs.join(order.root, 'elsewhere'),
      'beside-the-configuration',
      string.upper(jess.fs.join(order.data, 'Valleys.esp')),
    }

    local quoted = {}
    for _, path in ignoredPaths do
      table.insert(quoted, `"{path}"`)
    end

    jess.fs.write(
      jess.fs.join(order.config, 'merged_lands.toml'),
      `ignore_plugins_from_path = [{table.concat(quoted, ', ')}]\n`
    )

    local report = merge(order, {})
    expect(line(report)).toBe 'report: 9 lands, 6 merged, 0 seams, 1 textures, masters Base.esm, activated false'
    expect(report.plugins).toBe(2)
  end)

  suite.it('leaves out every plugin under a folder the options ignore', function()
    local order = support.order 'ignored-folder'

    local report = merge(order, { ignorePluginsFromPath = { `{order.data}/.` } })
    expect(line(report)).toBe 'report: 0 lands, 0 merged, 0 seams, 0 textures, masters , activated false'
    expect(report.plugins).toBe(0)

    -- A path that only starts like the data folder's ignores nothing in it.
    local beside = merge(order, { ignorePluginsFromPath = { `{order.data}-beside` } })
    expect(beside.plugins).toBe(3)
    support.expectOriginal(jess.fs.join(order.out, OutputName), 'default')
  end)

  suite.it('merges the plugins named, masters first, and as named when told not to sort', function()
    local order = support.order 'named'
    local named = { 'Hills.esp', 'Valleys.esp', 'Base.esm' }

    local report = merge(order, { plugins = named })
    expect(line(report)).toBe 'report: 12 lands, 7 merged, 71 seams, 4 textures, masters Base.esm Hills.esp Valleys.esp, activated false'
    support.expectOriginal(jess.fs.join(order.out, OutputName), 'default')

    local unsorted: { [string]: unknown } = { plugins = named, sortOrder = 'none' }
    expect(function() mergedLands({ mergedlands = unsorted }, openmw.new(order.file)) end).toThrow 'Hills.esp declares master Base.esm but loads before it'
    expect(unsorted.report).toBeNil()
  end)
end)

-- What the original's goldens don't reach either: a third plugin over the other two, changing
-- heights, normals, colors, textures, and world maps where they already changed them, so that
-- every part of a LAND conflicts under every strategy. No original wrote these; each plugin is
-- held to the SHA-256 of what the merge wrote for it before its loops were touched.
suite.describe('merging conflicts in every part', function()
  --- Storm.esp over Base.esm: the four cells both other plugins reach, each part of each changed
  --- across what Hills and Valleys changed.
  local function storm(order: support.Order)
    local plugin = tes3.new 'plugin'
    plugin:setAuthor 'test'
    plugin:setMasters {
      { name = 'Base.esm', size = assert(jess.fs.size(jess.fs.join(order.data, 'Base.esm'))) },
    }

    plugin:insertValue(
      plugin:count(),
      { type = 'LandscapeTexture', id = 'Grass', index = 0, fileName = 'tx_grass.dds' }
    )
    plugin:insertValue(
      plugin:count(),
      { type = 'LandscapeTexture', id = 'Ash', index = 1, fileName = 'tx_ash.dds' }
    )

    for cell = 0, 3 do
      local cellX, cellY = cell % 2, cell // 2
      local steps, slopes = buffer.create(Vertices * 4), buffer.create(Vertices * 3)
      local painted = buffer.create(Vertices * 3)
      local offset = 40 + (cellX * 64 * 3 + cellY * 64 * 2) % 50

      for vertex = 0, Vertices - 1 do
        local column, row = vertex % 65, vertex // 65
        local height = 40 + ((cellX * 64 + column) * 3 + (cellY * 64 + row) * 2) % 50
        local raised = column >= 10 and column <= 30 and row >= 5 and row <= 40
        buffer.writei32(steps, vertex * 4, height + (if raised then 18 else 0) - offset)

        buffer.writei8(slopes, vertex * 3, row * 2 % 30 - 15)
        buffer.writei8(slopes, vertex * 3 + 1, 7)
        buffer.writei8(slopes, vertex * 3 + 2, 110)

        local stained = column >= 5 and column <= 40 and row >= 5 and row <= 40
        buffer.writeu8(painted, vertex * 3, if stained then 10 + row else 90 + column)
        buffer.writeu8(painted, vertex * 3 + 1, if stained then 150 else 80 + row)
        buffer.writeu8(painted, vertex * 3 + 2, if stained then 20 + column else 60)
      end

      local indices, worldMap = buffer.create(512), buffer.create(81)
      for square = 0, 255 do
        buffer.writeu16(indices, square * 2, (square % 16 * 2 + square // 16) % 2 + 1)
      end

      for square = 0, 80 do
        buffer.writei8(worldMap, square, square % 5 + 4)
      end

      local index = plugin:count()
      plugin:insertValue(index, { type = 'Landscape', grid = { cellX, cellY } })
      tes3.land.write(plugin, index, {
        flags = 15,
        heightOffset = offset,
        heights = steps,
        normals = slopes,
        colors = painted,
        textures = indices,
        worldMap = worldMap,
      })
    end

    plugin:updateRecordCount()
    jess.fs.write(jess.fs.join(order.data, 'Storm.esp'), plugin:save())
  end

  --- Merges Base, Hills, Valleys, and Storm, each of the plugins' parts by `strategy` when one
  --- is given, and answers with the report's line and the digest of the plugin without the time.
  local function outcome(name: string, strategy: string?): string
    local content = table.clone(support.Standard)
    table.insert(content, 'Storm.esp')

    local order = support.order(name, nil, content)
    storm(order)

    if strategy then
      local lines = { 'version = "0"', 'meta_type = "Patch"' }
      for _, part in { 'height_map', 'vertex_colors', 'texture_indices', 'world_map_data' } do
        table.insert(lines, `\n[{part}]\nconflict_strategy = "{strategy}"`)
      end

      for _, plugin in { 'Hills', 'Valleys', 'Storm' } do
        jess.fs.write(
          jess.fs.join(order.data, `{plugin}.mergedlands.toml`),
          table.concat(lines, '\n') .. '\n'
        )
      end
    end

    local report = merge(order, {})
    local plugin = assert(jess.fs.readBuffer(report.output :: string))
    buffer.fill(plugin, DescriptionStart, 0, DescriptionLength)

    return `{line(report)}, {bytes.sha256(plugin)}`
  end

  -- Overwrite is what the load order does by default, so its plugin is the default's.
  local byLoadOrder =
    'report: 16 lands, 7 merged, 0 seams, 2 textures, masters Base.esm Storm.esp, activated false, 1da1171dfb4240612aae7ad3a65509af4990fc5f32fcd4439193a17fa4235ae6'

  suite.it('by load order', function() expect(outcome('conflicts', nil)).toBe(byLoadOrder) end)

  suite.it(
    'by Overwrite',
    function() expect(outcome('conflicts-overwrite', 'Overwrite')).toBe(byLoadOrder) end
  )

  suite.it('by Resolve', function()
    expect(outcome('conflicts-resolve', 'Resolve')).toBe 'report: 16 lands, 7 merged, 71 seams, 4 textures, masters Base.esm Hills.esp Storm.esp, activated false, 50aaa20faa879292fdcedcfdd94ca4542e29128fa722988d8833ebac7b1c6d25'
  end)

  suite.it('by Ignore', function()
    expect(outcome('conflicts-ignore', 'Ignore')).toBe 'report: 16 lands, 7 merged, 0 seams, 3 textures, masters Base.esm Storm.esp, activated false, 61b26e4d116784388c90ed4429760eef19c47ca8efb0ffcd466c01fa5c9422bc'
  end)
end)

return suite
