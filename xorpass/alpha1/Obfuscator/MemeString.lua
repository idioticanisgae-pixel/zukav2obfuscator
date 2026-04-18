-- ZukaTech Obfuscator - MemeString.lua
-- Injects junk calls to confuse reversers / make diffs harder

local Meme = {}

local MemePatterns = {
    "(function() return('scriptblox is a dogshit site') end)();",
    "(function() return('free my homie skippy #freehomie') end)();",
    "(function() return('shoutout to emi fr') end)();",
    "(function() return('where the fuck is emi giovanna?') end)();",
    "(function() return('when in doubt whip it out') end)();",
    "(function() return('hellen keller 3am discord') end)();",
    "(function() return('Stop reversing!!') end)();",
    "(function() return('Hello HackerMan') end)();",
    "(function() return('i did all of this on narcotics') end)();",
}

-- Seed once at module load time so repeated calls to GenerateMemeString()
-- within the same process tick don't all return the same pattern.
math.randomseed(os.time() + math.floor(os.clock() * 1e6))

-- Fisher-Yates shuffle a copy of the pattern list so we never repeat
-- the same string twice in one injection batch.
local function shuffledCopy(t)
    local c = {}
    for i = 1, #t do c[i] = t[i] end
    for i = #c, 2, -1 do
        local j = math.random(1, i)
        c[i], c[j] = c[j], c[i]
    end
    return c
end

-- Returns `count` unique meme strings as a single newline-joined block.
-- Falls back gracefully if count > #MemePatterns.
function Meme.GenerateMemeStrings(count)
    count = math.min(count or 1, #MemePatterns)
    local pool = shuffledCopy(MemePatterns)
    local out = {}
    for i = 1, count do
        out[i] = pool[i]
    end
    return table.concat(out, "\n")
end

-- Single-string variant kept for backwards compat.
function Meme.GenerateMemeString()
    return MemePatterns[math.random(1, #MemePatterns)]
end

return Meme