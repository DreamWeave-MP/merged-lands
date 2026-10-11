--!strict
--!native
-- What both suites build on: a load order in scratch holding `build.luau`'s plugins, with the
-- patch files in `patches/` beside them when a case asks, and the comparison with the plugins
-- Merged Lands 0.2.0 itself wrote for them (`golden/`).
local build = require './build'
local bytes = require '@dream/bytes'
local fs = require '@dream/fs'
local test = require '@jess/test'

local expect = test.expect

--- A load order's folders: the data folder holding the plugins, the folder of its openmw.cfg, and
--- its data-local folder.
export type Order = { root: string, data: string, config: string, out: string, file: string }

-- Where HEDR keeps the description, which ends in the time of the run: after the record header,
-- the subrecord header, the version, the file type, and the author.
local DescriptionStart, DescriptionLength = 64, 256

local Standard = table.freeze { 'Base.esm', 'Hills.esp', 'Valleys.esp' }

--- Where this file is, from its chunk name: the folder the suites and their goldens are in.
local function here(): string
  local source = debug.info(1, 's')
  local first = string.sub(source, 1, 1)
  local path = if first == '@' or first == '=' then string.sub(source, 2) else source

  return string.match(path, '^(.*)/[^/]*$') or '.'
end

local function io<Value>(value: Value?, message: string?, kind: dream_fs_ErrorKind?): Value
  if not value then error(message or tostring(kind), 0) end

  return value
end

--- The openmw.cfg of a load order over `content`, with or without its data-local folder.
local function configuration(order: Order, content: { string }, dataLocal: boolean): string
  local lines = { `data="{order.data}"` }
  if dataLocal then table.insert(lines, `data-local="{order.out}"`) end

  for _, name in content do
    table.insert(lines, `content={name}`)
  end

  return table.concat(lines, '\n') .. '\n'
end

--- A fresh load order named `name` under the suite's scratch folder: `build.luau`'s plugins in
--- its data folder with the `patches` beside them, the user's configuration in `config`, and
--- data-local in `out`. `content` is the content list, by default Base, Hills, Valleys.
local function order(name: string, patches: { string }?, content: { string }?): Order
  local scratch = assert(rawget(_G, 'scratchRoot') :: string?, 'the suite needs a scratchRoot')
  local root = jess.fs.join(scratch, name)

  -- A load order starts from nothing, whatever an earlier one of its name left behind.
  if jess.fs.isDir(root) then io(fs.remove(root, { recursive = true })) end

  local made: Order = {
    root = root,
    data = jess.fs.join(root, 'data'),
    config = jess.fs.join(root, 'config'),
    out = jess.fs.join(root, 'out'),
    file = jess.fs.join(root, 'config/openmw.cfg'),
  }

  for _, directory in { made.data, made.config, made.out } do
    io(fs.mkdir(directory, { recursive = true }))
  end

  build(made.data)
  for _, patch in patches or {} do
    jess.fs.write(jess.fs.join(made.data, patch), assert(jess.fs.read(`{here()}/patches/{patch}`)))
  end

  jess.fs.write(made.file, configuration(made, content or Standard, true))
  return made
end

--- The plugin the original wrote for the `golden` scenario.
local function golden(name: string): buffer
  return assert(jess.fs.readBuffer(`{here()}/golden/{name}.omwaddon`))
end

--- A plugin's bytes without the description, which says when the plugin was generated.
local function undated(plugin: buffer): buffer
  local copy = buffer.create(buffer.len(plugin))
  buffer.copy(copy, 0, plugin)
  buffer.fill(copy, DescriptionStart, 0, DescriptionLength)
  return copy
end

--- Holds the plugin at `path` to the original's for the `name` scenario, byte for byte but for
--- the time of the run. The length and digest are compared first: a failed comparison of the
--- bytes themselves can't be reported.
local function expectOriginal(path: string, name: string)
  local plugin, original = assert(jess.fs.readBuffer(path)), golden(name)
  expect(buffer.len(plugin)).toBe(buffer.len(original))

  local description = buffer.readstring(plugin, DescriptionStart, DescriptionLength)
  local opening = 'Merges landscape changes inside of cells.'
  expect(string.sub(description, 1, #opening)).toBe(opening)

  local written, expected = undated(plugin), undated(original)
  expect(bytes.sha256(written)).toBe(bytes.sha256(expected))
  expect(buffer.tostring(written) == buffer.tostring(expected)).toBe(true)
end

return table.freeze {
  Standard = Standard,
  configuration = configuration,
  expectOriginal = expectOriginal,
  golden = golden,
  order = order,
}
