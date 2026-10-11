--!strict
--!native
--[[
@merged-lands/cli: Merged Lands' command line, over `@merged-lands`.

  run(argv) -> exit status
  parse(argv) -> (command, nil) | (nil, message)
  configuration(command, environment) -> (openmw.cfg, nil) | (nil, message)

  merged-lands --openmw-cfg <path> [--output-file <name>] [--output-file-dir <dir>]
               [--sort-order default|none] [<plugin>...]
  merged-lands --help | --version

The flags are the original's (the `#[arg]`s of its `src/main.rs`), each onto the
`state.mergedlands` option the tool has for it: `--output-file` is `outputFile`,
`--output-file-dir` is `outputDir`, `--sort-order` is `sortOrder`, and the plugins named after the
flags are `plugins`. An option that wasn't given is left unset, for the tool's own default. As for
the original, a flag takes its value from the next argument or after an `=`, can be given once,
and `--` ends the flags.

The original names OpenMW's configuration with `--openmw-cfg`, a file or the folder holding it,
and finds OpenMW's own when it isn't given. Finding it is what this can't do, so the configuration
has to be named: by `--openmw-cfg`, by `--config`, which is the same flag as jess's other tools
spell it, or by the OPENMW_CONFIG environment variable when neither is given.

The original's other flags are for what the port doesn't do, and each is refused by name:
`--merged-lands-dir`, `--log-file`, and `--log-level` (no Conflicts images and no log are written,
and merged_lands.toml is read from beside openmw.cfg), `--vanilla` and `--data-files-dir` (this is
the OpenMW mode, the only one), `--stack-size-mb`, `--add-debug-vertex-colors`, and
`--wait-for-exit`.

`parse` reads an argument list into the command it names without running it, or says what it
couldn't read. `configuration` is the openmw.cfg a command reads, `environment` being
OPENMW_CONFIG's value. What a merge prints is the tool's own line for it.

Exit statuses: 0 when the command did what it was asked, 8 when the command line can't be used (an
unknown or unported flag, a missing or repeated value, no configuration, or one that isn't there),
9 when the merge raised. Messages go to standard error as `merged-lands: <message>`.
]]

local fs = require '@dream/fs'
local mergedLands = require '@merged-lands'
local openmw = require '@openmw'
local process = require '@dream/process'

--- `state.mergedlands`, as far as the command line sets it.
export type Options = {
  outputFile: string?,
  outputDir: string?,
  plugins: { string }?,
  sortOrder: ('default' | 'none')?,
}

--- A command line, read: for a merge, the configuration it names, if it names one, and the
--- options it sets.
export type Command = {
  action: 'merge' | 'help' | 'version',
  config: string?,
  options: Options?,
}

local Exit = table.freeze { ok = 0, invalidInput = 8, runtime = 9 }

local Usage = [[
merged-lands: Merged Lands for an OpenMW load order

  merged-lands --openmw-cfg <path> [--output-file <name>] [--output-file-dir <dir>]
               [--sort-order default|none] [<plugin>...]
  merged-lands --help | --version

Merges the load order's LAND records and writes what then differs from what OpenMW would load
anyway, with the LTEX records it uses, as one plugin that belongs last in the load order.

  <plugin>...              merge these plugins, by name, instead of openmw.cfg's content
  --openmw-cfg <path>      the openmw.cfg to read, or the folder holding it; --config is the
                           same, and OPENMW_CONFIG names it when neither is given
  --output-file <name>     the plugin's file name (default Merged Lands.omwaddon)
  --output-file-dir <dir>  where to write it (default merged_lands.toml's output_file_dir, else
                           data-local, else the first data folder)
  --sort-order <order>     default: the plugins given, and the masters, .esm first and then
                           oldest first; none: as given, and the masters in load order
  -h, --help               print this
  -V, --version            print which Merged Lands this is

Not ported, and refused: --merged-lands-dir, --log-file, --log-level, --vanilla,
--data-files-dir, --stack-size-mb, --add-debug-vertex-colors, --wait-for-exit.

Exit status: 0 done, 8 the command line can't be used, 9 the merge failed.]]

local Version = 'merged-lands: Merged Lands 0.2.0, ported to Luau'

-- The flags that take a value, by what the value is. Two spellings of one field are one flag.
local Valued: { [string]: { field: string, value: string } } = {
  ['--openmw-cfg'] = { field = 'config', value = 'an openmw.cfg or its folder' },
  ['--config'] = { field = 'config', value = 'an openmw.cfg or its folder' },
  ['--output-file'] = { field = 'outputFile', value = 'a file name' },
  ['--output-file-dir'] = { field = 'outputDir', value = 'a folder' },
  ['--sort-order'] = { field = 'sortOrder', value = 'default or none' },
}

-- The original's flags for what the port doesn't do, and why each has nothing to set.
local Unported: { [string]: string } = {
  ['--merged-lands-dir'] = 'no Conflicts images or log are written, and merged_lands.toml is read from beside openmw.cfg',
  ['--log-file'] = 'no log file is written',
  ['--log-level'] = 'no log file is written',
  ['--vanilla'] = 'this is the OpenMW mode, and the only one',
  ['--data-files-dir'] = 'it is --vanilla\'s, and this is the OpenMW mode, the only one',
  ['--stack-size-mb'] = 'the merge has no thread of its own to size a stack for',
  ['--add-debug-vertex-colors'] = 'the merge colors no vertices to show conflicts',
  ['--wait-for-exit'] = 'the command never waits for a key',
}

local function out(text: string) process.write('stdout', `{text}\n`) end

local function err(text: string) process.write('stderr', `{text}\n`) end

local function usage(message: string): number
  err(`merged-lands: {message}`)
  return Exit.invalidInput
end

local function parse(argv: { string }): (Command?, string?)
  local options: Options = {}
  local plugins: { string } = {}
  -- Each field a flag has set, by the flag that set it.
  local given: { [string]: string } = {}
  local config: string?
  local index = 1

  while index <= #argv do
    local argument = argv[index]
    index += 1

    if argument == '--' then
      table.move(argv, index, #argv, #plugins + 1, plugins)
      break
    end

    if argument == '-h' or argument == '--help' then return { action = 'help' :: 'help' }, nil end

    if argument == '-V' or argument == '--version' then
      return { action = 'version' :: 'version' }, nil
    end

    if string.sub(argument, 1, 1) ~= '-' or argument == '-' then
      table.insert(plugins, argument)
      continue
    end

    local flag, attached = string.match(argument, '^(%-%-[^=]+)=(.*)$')
    local name: string = flag or argument

    local unported = Unported[name]
    if unported then return nil, `{name} isn't ported: {unported}` end

    local valued = Valued[name]
    if not valued then return nil, `unknown option '{argument}'` end

    local value: string? = attached
    if not value then
      value = argv[index]
      index += 1
    end

    if not value then return nil, `{name} requires {valued.value}` end

    local field = valued.field
    local first = given[field]
    if first == name then return nil, `{name} can only be given once` end
    if first then return nil, `{first} and {name} both name the configuration; give one` end

    given[field] = name

    if field == 'config' then
      config = value
    elseif field == 'outputFile' then
      options.outputFile = value
    elseif field == 'outputDir' then
      options.outputDir = value
    elseif value == 'default' or value == 'none' then
      options.sortOrder = value
    else
      return nil, `--sort-order takes default or none, not '{value}'`
    end
  end

  if #plugins > 0 then options.plugins = plugins end

  return { action = 'merge' :: 'merge', config = config, options = options }, nil
end

--- The openmw.cfg in `directory`, whatever the case of its name.
local function configurationIn(directory: string): (string?, string?)
  local names, message = fs.list(directory)
  if not names then return nil, `can't look for an openmw.cfg in '{directory}': {message}` end

  for _, name in names do
    if string.lower(name) == 'openmw.cfg' then return jess.fs.join(directory, name), nil end
  end

  return nil, `there's no openmw.cfg in '{directory}'`
end

--- The openmw.cfg `command` reads: the one its flag names, else the one `environment` does, that
--- being OPENMW_CONFIG's value; either may be the file or the folder holding it. Nil and why when
--- neither names one that's there.
local function configuration(command: Command, environment: string?): (string?, string?)
  local selected = command.config
  if not selected and environment ~= '' then selected = environment end

  if not selected then
    return nil,
      'an OpenMW configuration is required: name the openmw.cfg or its folder with --openmw-cfg (or --config), or in OPENMW_CONFIG'
  end

  if jess.fs.isFile(selected) then return selected, nil end
  if jess.fs.isDir(selected) then return configurationIn(selected) end

  return nil, `'{selected}' isn't an openmw.cfg or a folder holding one`
end

--- What stopped a merge, as the tool worded it: Luau puts the script's position in front of a
--- message, and most of the tool's messages start with its name, which the command line adds.
local function worded(problem: unknown): string
  local text = tostring(problem)
  text = string.gsub(text, '^[^:\n]+:%d+: ', '', 1)
  text = string.gsub(text, '^merged%-lands: ', '', 1)
  return text
end

local function merge(path: string, options: Options)
  local state: { [string]: unknown } = { mergedlands = options }
  mergedLands(state, openmw.new(path))
end

local function run(argv: { string }): number
  local command, message = parse(argv)
  if not command then return usage(message :: string) end

  if command.action == 'help' then
    out(Usage)
    return Exit.ok
  end

  if command.action == 'version' then
    out(Version)
    return Exit.ok
  end

  -- A configuration a flag names is read whatever the environment says.
  local environment = if command.config then nil else process.env 'OPENMW_CONFIG'
  local path, missing = configuration(command, environment)
  if not path then return usage(missing :: string) end

  -- The merge raises where the original stops with an error: an openmw.cfg that can't be read, a
  -- load order whose masters are missing or out of order, a LAND it can't stack on the one before
  -- it, no folder to write the plugin to.
  local merged, problem = pcall(merge, path, command.options :: Options)
  if not merged then
    err(`merged-lands: {worded(problem)}`)
    return Exit.runtime
  end

  return Exit.ok
end

return table.freeze {
  Exit = Exit,
  configuration = configuration,
  parse = parse,
  run = run,
}
