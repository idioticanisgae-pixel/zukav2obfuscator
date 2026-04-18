-- hex.lua
-- Generates names in the style of compiled C output / memory addresses
-- e.g. _0xA3F2, _0x1B9C4D — looks like decompiled binary, not hand-written code



-- Prefix pool — varied styles so not every name looks identical
local prefixes = {
    "_0x",   -- classic hex
    "__0x",  -- double underscore (looks like internal compiler symbol)
    "_x",    -- shortened
    "_h",    -- 'h' for hex
    "_",     -- plain underscore + hex digits
}

-- How many hex digits per name (varied for realism)
local MIN_DIGITS = 3
local MAX_DIGITS = 6

local hexChars = { "0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F" }
local seed     = 0

local function generateName(id, scope)
    -- deterministic but non-sequential hex value derived from id + seed
    local val    = (id * 2654435761 + seed) % 0xFFFFFF
    local digits = MIN_DIGITS + (id % (MAX_DIGITS - MIN_DIGITS + 1))
    local prefix = prefixes[(id % #prefixes) + 1]

    local hex = ""
    local v   = val
    for i = 1, digits do
        hex = hexChars[(v % 16) + 1] .. hex
        v   = math.floor(v / 16)
    end

    -- Pad with leading zeros if needed
    while #hex < digits do
        hex = "0" .. hex
    end

    return prefix .. hex
end

local function prepare(ast)
    util.shuffle(prefixes)
    seed = math.random(0, 0xFFFF)
end

return {
    generateName = generateName,
    prepare      = prepare,
}
