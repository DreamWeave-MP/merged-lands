--!strict
--!native
-- `@merged-lands` over a load order, held to Merged Lands 0.2.0's own output: the plugins in
-- `golden/` are what the original wrote for the plugins `build.luau` makes, `patched` with the
-- `.mergedlands.toml` files in `patches/` beside them. The header's description ends in the time
-- of the run, so it's left out of the comparison, and nothing else is. `jess package test` runs
-- every case from the package's source and from its packed JPK.
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

return suite
