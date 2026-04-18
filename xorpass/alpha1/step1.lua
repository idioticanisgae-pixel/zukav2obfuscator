-- ╔══════════════════════════════════════════════════════════╗
-- ║              ZukaTech Obfuscator v2 - init.lua  [FIXED]  ║
-- ╚══════════════════════════════════════════════════════════╝
-- FIXES applied vs original:
--   #1  Pipeline order: watermark / anti-tamper / memes are now injected
--       AFTER stringEncryptV2 so they live in the plaintext outer shell
--       (previously they were buried inside the encrypted blob)
--   #2  `warn or print` crash on Lua 5.1 / executors without `warn`
--       → replaced with a safe pcall probe
--   #3  `loadstring` only → `(loadstring or load)` for Lua 5.2+ compat
--   #4  Meme dedup: repeated strings caused by re-seeding per call fixed
--       → uses GenerateMemeStrings(n) from the patched MemeString.lua

package.path = "./?.lua;./Obfuscator/?.lua;./Obfuscator/Lua/?.lua;./Obfuscator/Lua/Minifier/?.lua;" .. package.path

-- ── Globals required by sub-modules ──────────────────────────────────────────

config = {
    NameUpper   = "ZUKTECH",
    IdentPrefix = "__ZukaTech",
}

if not colors then
    colors = function(str, _color) return tostring(str) end
end

util = util or {}
function util.shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

utils = utils or {}
function utils.chararray(str)
    local t = {}
    for i = 1, #str do t[i] = str:sub(i, i) end
    return t
end

-- ── Load modules ──────────────────────────────────────────────────────────────

local logger          = require("Obfuscator.logger")
local Minifier        = require("Obfuscator.Lua.Minifier.init")
local StringEncrypt   = require("Obfuscator.StringEncryption")
local StringEncoder   = require("Obfuscator.string_encoder")
local VariableRenamer = require("Obfuscator.variable_renamer")
local WrapInFunction  = require("Obfuscator.WrapInFunction")
local MemeString      = require("Obfuscator.MemeString")
local Watermark       = require("Obfuscator.Watermark")
--local AntiTamper      = require("Obfuscator.AntiTamper")
local Hex             = require("Obfuscator.hex")

-- ── Options ───────────────────────────────────────────────────────────────────

local Options = {
    minify          = false,
    renameVariables = true,
    stringEncrypt   = true,   -- Caesar-cipher string literals + inline decoder
    stringEncryptV2 = true,   -- XOR/compress full source → self-decrypting loader
    wrapInFunction  = true,
    watermark       = false,
    --antiTamper      = false,
    memeStrings     = true,
    memeCount       = 1,
    hexNames        = true,  -- true = _0xABCD style names
    varNameMinLen   = 8,
    varNameMaxLen   = 14,
}

-- ── I/O ───────────────────────────────────────────────────────────────────────

local inputPath  = "input.lua"
local outputPath = "output.lua"

local fIn = io.open(inputPath, "r")
if not fIn then error("[ZukaTech] Cannot open input: " .. inputPath) end
local source = fIn:read("*a"); fIn:close()
if not source or #source == 0 then error("[ZukaTech] Input is empty") end
logger:log("Loaded " .. #source .. " bytes")

-- ─────────────────────────────────────────────────────────────────────────────
-- PIPELINE  (order is load-bearing — do not shuffle)
--
--  Steps 1-4  transform the PAYLOAD (user code).
--  Steps 5-7  inject OUTER SHELL code around the already-encrypted loader.
--             Running them before step 4 was the original bug — the shell
--             code got encrypted away and never executed.
--  Step  8    wraps everything.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Minify ─────────────────────────────────────────────────────────────────

if Options.minify then
    local ok, r = pcall(Minifier.optimize, Minifier.DEFAULT_OPTS, source)
    if ok and r and #r > 0 then
        source = r
        logger:log("Minified → " .. #source .. " bytes")
    else
        logger:warn("Minifier failed, skipping")
    end
end

-- ── 2. Rename variables / functions ──────────────────────────────────────────

if Options.renameVariables then
    local nameGen = nil
    if Options.hexNames then Hex.prepare(); nameGen = Hex end
    local ok, r = pcall(VariableRenamer.process, source, {
        min_length    = Options.varNameMinLen,
        max_length    = Options.varNameMaxLen,
        namegenerator = nameGen,
    })
    if ok and r and #r > 0 then
        source = r
        logger:log("Renamed vars → " .. #source .. " bytes")
    else
        logger:warn("VariableRenamer failed, skipping")
    end
end

-- ── 3. Caesar-cipher string literals ─────────────────────────────────────────

if Options.stringEncrypt then
    local ok, r = pcall(StringEncoder.process, source)
    if ok and r and #r > 0 then
        source = r
        logger:log("Caesar strings → " .. #source .. " bytes")
    else
        logger:warn("StringEncoder failed, skipping")
    end
end

-- ── 4. XOR/compress full source into self-decrypting loader ──────────────────

if Options.stringEncryptV2 then
    local ok, r = pcall(function()

        -- FIX #2: safe warn probe — bare `warn` throws on Lua 5.1 / some executors
        local warnSafe = [[local __warn=(function()
    local _ok,_f=pcall(function()return warn end)
    return(_ok and type(_f)=="function")and _f or print
end)()]]

        -- stdlib aliases used inside the decrypt stub
        local stdlib = "local Sub,Byte,Char,Find,Floor,Pairs,Insert,Pcall,ToNumber=" ..
            "string.sub,string.byte,string.char,string.find," ..
            "math.floor,pairs,table.insert,pcall,tonumber;"

        -- encrypted_table indices referenced by the AntiTamper stub
        -- FIX #2 continued: index 7 uses __warn instead of bare warn
        local encTable = "local encrypted_table={[6]=print,[7]=__warn,[8]=error,[10]=function()end};"

        local encrypted   = StringEncrypt:Encrypt(source)
        local decodeBlock = StringEncrypt.AddDecodeCode(encrypted)

        -- FIX #3: `(loadstring or load)` covers Lua 5.1 and 5.2+
        local loader = [[
if ARR then
    local _src=table.concat(ARR)
    local _fn,_err=(loadstring or load)(_src)
    if _fn then _fn() else error("uwu cutie error: "..tostring(_err)) end
end
]]
        return warnSafe.."\n"..stdlib.."\n"..encTable.."\n"..decodeBlock..loader
    end)

    if ok and r and #r > 0 then
        source = r
        logger:log("EncryptV2 → " .. #source .. " bytes")
    else
        logger:warn("StringEncryptV2 failed, skipping")
    end
end

-- ── 5. Meme strings — OUTER SHELL (after encrypt) ────────────────────────────
-- FIX #1 + #4: prepend to the already-encrypted loader so they're visible
-- plaintext, and use GenerateMemeStrings(n) to guarantee no duplicates.

if Options.memeStrings then
    local memeBlock
    if MemeString.GenerateMemeStrings then
        -- patched MemeString.lua with dedup support
        memeBlock = MemeString.GenerateMemeStrings(Options.memeCount)
    else
        -- fallback for original MemeString.lua: retry loop to avoid dupes
        local seen, out = {}, {}
        local tries = 0
        while #out < Options.memeCount and tries < 100 do
            local s = MemeString.GenerateMemeString()
            if not seen[s] then seen[s] = true; out[#out+1] = s end
            tries = tries + 1
        end
        memeBlock = table.concat(out, "\n")
    end
    source = memeBlock .. "\n" .. source
    logger:log("Meme strings injected (outer)")
end

-- ── 6. Watermark — OUTER SHELL (after encrypt) ───────────────────────────────
-- FIX #1: previously prepended before encrypt → watermark was encrypted away

if Options.watermark and Watermark.Enabled then
    local mark = Watermark.WaterMarkAdd()
    if mark then
        source = mark .. "\n" .. source
        logger:log("Watermark injected (outer)")
    end
end

-- ── 7. Anti-tamper — OUTER SHELL (after encrypt) ─────────────────────────────
-- FIX #1: same as watermark — must live outside the encrypted layer

if Options.antiTamper then
    local ok, block = pcall(function() return AntiTamper:Apply() end)
    if ok and block then
        source = block .. "\n" .. source
        logger:log("Anti-tamper injected (outer)")
    else
        logger:warn("AntiTamper failed, skipping")
    end
end

-- ── 8. Wrap in function ───────────────────────────────────────────────────────

if Options.wrapInFunction then
    source = WrapInFunction.process(source)
    logger:log("Wrapped in function")
end

-- ── Write ─────────────────────────────────────────────────────────────────────

local fOut = io.open(outputPath, "w")
if not fOut then error("[ZukaTech] Cannot open output: " .. outputPath) end
fOut:write(source); fOut:close()
logger:log("Done → " .. outputPath .. " (" .. #source .. " bytes)")