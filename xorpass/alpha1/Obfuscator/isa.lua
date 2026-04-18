-- ZukaTech/compiler/isa.lua
-- Custom Instruction Set Architecture for the ZukaTech bytecode backend.
--
-- This ISA is designed from scratch — it shares no encoding, opcode numbering,
-- or operand layout with Lua 5.1, IronBrew2, Luraph, or any other obfuscator.
-- Every aspect is randomisable at compile time (opcode shuffle, XOR key,
-- register width, constant pool encoding) so each obfuscation pass produces
-- a structurally distinct binary layout.
--
-- INSTRUCTION FORMAT (fixed 6 bytes per instruction):
--   Byte 0:  opcode  (0-255, shuffled per-compile via OPCODE_MAP)
--   Byte 1:  A       (destination / primary register, 0-255)
--   Byte 2:  B_hi    \
--   Byte 3:  B_lo    /  B = 16-bit unsigned (source reg or immediate)
--   Byte 4:  C_hi    \
--   Byte 5:  C_lo    /  C = 16-bit unsigned (source reg or immediate)
--
-- All bytes are XOR'd with a per-compile key before serialisation.
-- The runtime VM holds the XOR key and decodes on the fly.
--
-- CONSTANT POOL (per-proto):
--   Serialised before the instruction stream.
--   Format: [count:2 bytes][entry...entry]
--   Each entry: [type:1 byte][data...]
--     type 0 = nil      (no data)
--     type 1 = boolean  [value:1 byte]
--     type 2 = integer  [val:4 bytes, big-endian signed]
--     type 3 = float    [val:8 bytes, IEEE-754 little-endian]
--     type 4 = string   [len:2 bytes][utf-8 bytes]
--
-- PROTO TABLE:
--   Each proto (function prototype) contains:
--     [param_count:1][is_vararg:1][reg_count:1]
--     [const_count:2][consts...]
--     [instr_count:2][instrs...] (each 6 bytes)
--     [proto_count:1][nested_protos...]

local ISA = {}

-- ── Canonical opcode names ────────────────────────────────────────────────────

ISA.OP = {
    LOADNIL      = 0,   -- R[A] = nil
    LOADBOOL     = 1,   -- R[A] = (B ~= 0)
    LOADINT      = 2,   -- R[A] = signed(B<<16|C)  (32-bit int via two 16-bit halves)
    LOADFLOAT    = 3,   -- R[A] = Const[B]  (float from const pool)
    LOADSTR      = 4,   -- R[A] = Const[B]  (string from const pool)
    MOVE         = 5,   -- R[A] = R[B]
    GETGLOBAL    = 6,   -- R[A] = Env[Const[B]]
    SETGLOBAL    = 7,   -- Env[Const[B]] = R[A]
    GETTABLE     = 8,   -- R[A] = R[B][R[C]]
    SETTABLE     = 9,   -- R[A][R[B]] = R[C]
    NEWTABLE     = 10,  -- R[A] = {}
    ADD          = 11,  -- R[A] = R[B] + R[C]
    SUB          = 12,  -- R[A] = R[B] - R[C]
    MUL          = 13,  -- R[A] = R[B] * R[C]
    DIV          = 14,  -- R[A] = R[B] / R[C]
    MOD          = 15,  -- R[A] = R[B] % R[C]
    POW          = 16,  -- R[A] = R[B] ^ R[C]
    CONCAT       = 17,  -- R[A] = R[B] .. R[C]
    LT           = 18,  -- R[A] = (R[B] < R[C])
    LE           = 19,  -- R[A] = (R[B] <= R[C])
    EQ           = 20,  -- R[A] = (R[B] == R[C])
    NE           = 21,  -- R[A] = (R[B] ~= R[C])
    GT           = 22,  -- R[A] = (R[B] > R[C])
    GE           = 23,  -- R[A] = (R[B] >= R[C])
    NOT          = 24,  -- R[A] = not R[B]
    UNM          = 25,  -- R[A] = -R[B]
    LEN          = 26,  -- R[A] = #R[B]
    CALL         = 27,  -- R[A..A+C-2] = R[A](R[A+1..A+B-1])
    CALLM        = 28,  -- {R[A..Top]} = R[A](R[A+1..Top])  (multi-ret into table)
    VCALL        = 29,  -- R[A](R[A+1..A+B-1])  (void: discard results)
    JMP          = 30,  -- PC = B  (absolute instruction index)
    JMPT         = 31,  -- if R[A] then PC = B
    JMPF         = 32,  -- if not R[A] then PC = B
    RETURN       = 33,  -- return R[A..A+B-2]  (B=1 means return nothing)
    RETURNM      = 34,  -- return unpack(R[A])  (R[A] is a packed-results table)
    ALLOC_UPVAL  = 35,  -- R[A] = allocUpval()
    GET_UPVAL    = 36,  -- R[A] = upvalTable[R[B]]
    SET_UPVAL    = 37,  -- upvalTable[R[A]] = R[B]
    UPVAL_GET    = 38,  -- R[A] = upvals[B][R[C]]  (read from closure upval slot)
    UPVAL_SET    = 39,  -- upvals[B][R[C]] = R[A]  (write to closure upval slot)
    CLOSURE      = 40,  -- R[A] = Closure(Proto[B], upvals_start=C)
    VARARG       = 41,  -- R[A..A+B-2] = vararg[1..B-1]  (B=0 = all into table at A)
    SETRET       = 42,  -- retbuf[A] = R[B]  (build return buffer)
    SETRETM      = 43,  -- retbuf = unpack(R[A]) (pack multi-return into retbuf)
    FREE_UPVAL   = 44,  -- freeUpval(R[A])
}

ISA.OP_COUNT = 45  -- total opcodes

-- ── Opcode shuffle ────────────────────────────────────────────────────────────
-- Returns two tables: encode[canonical] = wire, decode[wire] = canonical
-- A random permutation of 0..255 is generated each compilation.
function ISA.makeOpcodeMap(rng)
    rng = rng or math.random
    -- Build a permutation of 0..255
    local perm = {}
    for i = 0, 255 do perm[i+1] = i end
    -- Fisher-Yates — clamp j so floating point edge cases can't go out of bounds
    for i = 256, 2, -1 do
        local r = rng()
        -- Guard: r must be in [0,1); clamp to prevent index > i
        if r >= 1 then r = 0.9999999 end
        if r < 0  then r = 0 end
        local j = math.floor(r * i) + 1
        if j < 1 then j = 1 end
        if j > i then j = i end
        perm[i], perm[j] = perm[j], perm[i]
    end
    local encode = {}  -- canonical -> wire
    local decode = {}  -- wire -> canonical
    for canonical = 0, ISA.OP_COUNT - 1 do
        local wire = perm[canonical + 1]
        encode[canonical] = wire
        decode[wire] = canonical
    end
    return encode, decode
end

-- ── Instruction encoding ──────────────────────────────────────────────────────

-- Pack one instruction into a 6-byte string.
-- xorKey is applied to every byte.
function ISA.packInstr(opcode, a, b, c, xorKey)
    xorKey = xorKey or 0
    a   = a or 0
    b   = b or 0
    c   = c or 0
    -- Clamp/mask
    opcode = opcode % 256
    a      = a      % 256
    b      = b % 65536
    c      = c % 65536
    local b_hi = math.floor(b / 256) % 256
    local b_lo = b % 256
    local c_hi = math.floor(c / 256) % 256
    local c_lo = c % 256
    -- XOR each byte (Lua 5.1 compatible)
    local function x(v)
        local a, b, r, m = v, xorKey, 0, 1
        while a > 0 or b > 0 do
            local ra, rb = a % 2, b % 2
            if ra ~= rb then r = r + m end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            m = m * 2
        end
        return r % 256
    end
    return string.char(x(opcode), x(a), x(b_hi), x(b_lo), x(c_hi), x(c_lo))
end

-- Unpack a 6-byte instruction (already XOR-decoded by caller)
function ISA.unpackInstr(s, pos)
    pos = pos or 1
    local op = s:byte(pos)
    local a  = s:byte(pos+1)
    local bh = s:byte(pos+2)
    local bl = s:byte(pos+3)
    local ch = s:byte(pos+4)
    local cl = s:byte(pos+5)
    return op, a, bh*256+bl, ch*256+cl
end

-- ── Constant pool serialisation ───────────────────────────────────────────────

local function pack2(n)
    n = n % 65536
    return string.char(math.floor(n/256), n%256)
end

local function pack4(n)
    -- big-endian signed 32-bit
    if n < 0 then n = n + 4294967296 end
    n = n % 4294967296
    return string.char(
        math.floor(n/16777216)%256,
        math.floor(n/65536)%256,
        math.floor(n/256)%256,
        n%256
    )
end

local function unpack2(s, pos)
    return s:byte(pos)*256 + s:byte(pos+1), pos+2
end

local function unpack4(s, pos)
    local v = s:byte(pos)*16777216 + s:byte(pos+1)*65536
            + s:byte(pos+2)*256    + s:byte(pos+3)
    if v >= 2147483648 then v = v - 4294967296 end
    return v, pos+4
end

-- IEEE-754 double serialiser (little-endian, same as IB2's gFloat)
local function packFloat(n)
    if n == 0 then return string.rep("\0", 8) end
    local sign = 0
    if n < 0 then sign = 1; n = -n end
    local exp = 0
    local mant = n
    if mant >= 1 then
        while mant >= 2 do mant = mant / 2; exp = exp + 1 end
    else
        while mant < 1 do mant = mant * 2; exp = exp - 1 end
    end
    exp = exp + 1023
    mant = mant - 1  -- implicit leading 1
    -- mant is now in [0,1), multiply by 2^52
    local m52 = mant * (2^52)
    local mlo = m52 % 4294967296
    local mhi = math.floor(m52 / 4294967296) % 1048576  -- 20 bits
    local hi32 = sign * 2147483648 + exp * 1048576 + mhi
    -- little-endian
    local lo = mlo
    local hi = hi32
    local function b(v, sh) return math.floor(v / 2^sh) % 256 end
    return string.char(
        b(lo,0),b(lo,8),b(lo,16),b(lo,24),
        b(hi,0),b(hi,8),b(hi,16),b(hi,24)
    )
end

local function unpackFloat(s, pos)
    local b = {s:byte(pos, pos+7)}
    local lo = b[1] + b[2]*256 + b[3]*65536 + b[4]*16777216
    local hi = b[5] + b[6]*256 + b[7]*65536 + b[8]*16777216
    if lo == 0 and hi == 0 then return 0, pos+8 end
    local sign   = math.floor(hi / 2147483648)
    local exp    = math.floor(hi / 1048576) % 2048
    local mhi    = hi % 1048576
    local mant   = (mhi * 4294967296 + lo) / (2^52) + 1
    local result = ((-1)^sign) * (2^(exp-1023)) * mant
    return result, pos+8
end

-- Serialise a constant pool entry
-- Returns a byte string
local function serialiseConst(v)
    local t = type(v)
    if t == "nil" then
        return "\0"
    elseif t == "boolean" then
        return "\1" .. (v and "\1" or "\0")
    elseif t == "number" then
        if v == math.floor(v) and v >= -2147483648 and v <= 2147483647 then
            return "\2" .. pack4(math.floor(v))
        else
            return "\3" .. packFloat(v)
        end
    elseif t == "string" then
        local len = #v
        return "\4" .. pack2(len) .. v
    end
    error("Cannot serialise constant of type " .. t)
end

-- Deserialise one constant from a string at position pos
-- Returns: value, new_pos
local function deserialiseConst(s, pos)
    local ctype = s:byte(pos); pos = pos + 1
    if ctype == 0 then
        return nil, pos
    elseif ctype == 1 then
        local v = s:byte(pos) ~= 0; pos = pos + 1
        return v, pos
    elseif ctype == 2 then
        local v; v, pos = unpack4(s, pos)
        return v, pos
    elseif ctype == 3 then
        local v; v, pos = unpackFloat(s, pos)
        return v, pos
    elseif ctype == 4 then
        local len; len, pos = unpack2(s, pos)
        local v = s:sub(pos, pos + len - 1)
        return v, pos + len
    end
    error("Unknown const type " .. tostring(ctype))
end

ISA.serialiseConst   = serialiseConst
ISA.deserialiseConst = deserialiseConst
ISA.pack2    = pack2
ISA.unpack2  = unpack2
ISA.pack4    = pack4
ISA.unpack4  = unpack4
ISA.packFloat   = packFloat
ISA.unpackFloat = unpackFloat

-- ── Proto serialisation ───────────────────────────────────────────────────────
-- A Proto is a table:
-- {
--   params      = integer,
--   is_vararg   = bool,
--   max_reg     = integer,
--   consts      = { val, val, ... },
--   instrs      = { {op,a,b,c}, ... },
--   protos      = { Proto, ... },  -- nested functions
-- }

function ISA.serialiseProto(proto, xorKey, encodeOp)
    xorKey   = xorKey   or 0
    encodeOp = encodeOp or function(op) return op end

    local parts = {}

    -- Header
    parts[#parts+1] = string.char(
        proto.params   % 256,
        (proto.is_vararg and 1 or 0),
        proto.max_reg  % 256
    )

    -- Constant pool
    local constData = {}
    for _, v in ipairs(proto.consts) do
        constData[#constData+1] = serialiseConst(v)
    end
    local constBlob = table.concat(constData)
    parts[#parts+1] = pack2(#proto.consts) .. constBlob

    -- Instructions
    local instrData = {}
    for _, instr in ipairs(proto.instrs) do
        instrData[#instrData+1] = ISA.packInstr(
            encodeOp(instr[1]), instr[2], instr[3], instr[4], xorKey
        )
    end
    parts[#parts+1] = pack2(#proto.instrs) .. table.concat(instrData)

    -- Nested protos (recursive)
    parts[#parts+1] = string.char(#proto.protos % 256)
    for _, sub in ipairs(proto.protos) do
        parts[#parts+1] = ISA.serialiseProto(sub, xorKey, encodeOp)
    end

    return table.concat(parts)
end

function ISA.deserialiseProto(s, pos, xorKey, decodeMap)
    xorKey    = xorKey    or 0
    decodeMap = decodeMap or {}
    pos       = pos       or 1
    -- wrap as lookup function
    local function decodeOp(wire)
        return decodeMap[wire] or wire
    end

    local proto = {
        params    = 0,
        is_vararg = false,
        max_reg   = 0,
        consts    = {},
        instrs    = {},
        protos    = {},
    }

    -- Header
    proto.params    = s:byte(pos);     pos = pos + 1
    proto.is_vararg = s:byte(pos) ~= 0; pos = pos + 1
    proto.max_reg   = s:byte(pos);     pos = pos + 1

    -- Constants
    local nconsts; nconsts, pos = unpack2(s, pos)
    for i = 1, nconsts do
        local v; v, pos = deserialiseConst(s, pos)
        proto.consts[i] = v
    end

    -- Instructions
    local ninstrs; ninstrs, pos = unpack2(s, pos)
    for i = 1, ninstrs do
        local raw = s:sub(pos, pos+5)
        -- XOR decode each byte
        local bytes = {}
        for j = 1, 6 do
            local b = raw:byte(j)
            -- Lua 5.1 XOR
            local r, m = 0, 1
            local av, bv = b, xorKey
            while av > 0 or bv > 0 do
                local ra, rb = av%2, bv%2
                if ra ~= rb then r = r + m end
                av = math.floor(av/2); bv = math.floor(bv/2); m = m*2
            end
            bytes[j] = r
        end
        local op = decodeOp(bytes[1])
        local a  = bytes[2]
        local b  = bytes[3]*256 + bytes[4]
        local c2 = bytes[5]*256 + bytes[6]
        proto.instrs[i] = {op, a, b, c2}
        pos = pos + 6
    end

    -- Nested protos
    local nprotos = s:byte(pos); pos = pos + 1
    for i = 1, nprotos do
        local sub; sub, pos = ISA.deserialiseProto(s, pos, xorKey, decodeMap)
        proto.protos[i] = sub
    end

    return proto, pos
end

return ISA
