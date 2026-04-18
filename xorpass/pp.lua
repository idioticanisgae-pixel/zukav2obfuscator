local pprint = require("pprint")

local function usage()
    print("Usage:")
    print("lua luacli.lua <script.lua> [args...]")
    os.exit(1)
end

if not arg[1] then
    usage()
end

local script = arg[1]

-- Get directory + filename
local dir = script:match("^(.*[\\/])") or "./"
local filename = script:match("([^\\/]+)$") or "output.lua"
local name = filename:gsub("%.lua$", "")

-- shift args for target script
local scriptArgs = {}
for i = 2, #arg do
    scriptArgs[i - 1] = arg[i]
end

_G.arg = scriptArgs

local chunk, err = loadfile(script)

if not chunk then
    print("Failed to load script:")
    print(err)
    os.exit(1)
end

local ok, result = pcall(chunk)

if not ok then
    print("Runtime error:")
    print(result)
    os.exit(1)
end

-- Pretty print result
local pretty = pprint.pformat(result)

-- Save beside original script
local outFile = dir .. name .. "_pretty.lua"

local file = io.open(outFile, "w")
if not file then
    print("Failed to create output file.")
    os.exit(1)
end

file:write(pretty)
file:close()

print("Saved pretty output to: " .. outFile)
