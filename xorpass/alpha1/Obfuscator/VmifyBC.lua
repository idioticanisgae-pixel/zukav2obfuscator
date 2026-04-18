
local ISA       = require("isa")
local BCFactory = require("compiler")
local logger    = require("logger")

local LuaVersion = Enums.LuaVersion
local OP         = ISA.OP

local VmifyBC       = Step:extend()
VmifyBC.Description = "Compiles script to a custom ZukaTech bytecode blob + inline VM (IronBrew2-style, custom ISA)."
VmifyBC.Name        = "VmifyBC"

VmifyBC.SettingsDescriptor = {
    XorKey = {
        name = "XorKey", type = "number", default = 0, min = 0, max = 254,
        description = "Bytecode XOR key 1-254 (0 = random per compile)",
    },
    ShuffleOpcodes = {
        name = "ShuffleOpcodes", type = "boolean", default = true,
        description = "Randomly permute opcode wire values each compilation",
    },
}

function VmifyBC:init(settings) end

-- ── LZW compress ──────────────────────────────────────────────────────────────

local C36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
    if n == 0 then return "0" end
    local s = ""
    while n > 0 do
        s = C36:sub(n%36+1,n%36+1)..s
        n = math.floor(n/36)
    end
    return s
end
local function eCode(n) local s=b36(n); return b36(#s)..s end
local function lzw(inp)
    local d,ds={},256
    for i=0,255 do d[string.char(i)]=i end
    local w,o="",{}
    for i=1,#inp do
        local c=inp:sub(i,i); local wc=w..c
        if d[wc] then w=wc
        else o[#o+1]=eCode(d[w]); d[wc]=ds; ds=ds+1; w=c end
    end
    if w~="" then o[#o+1]=eCode(d[w]) end
    return table.concat(o)
end

-- ── bxor (Lua 5.1) ────────────────────────────────────────────────────────────

local function bx(a,b)
    local r,m=0,1
    while a>0 or b>0 do
        local ra,rb=a%2,b%2
        if ra~=rb then r=r+m end
        a=math.floor(a/2); b=math.floor(b/2); m=m*2
    end
    return r
end
local function xorB(s,k)
    local t={}
    for i=1,#s do t[i]=string.char(bx(s:byte(i),k)%256) end
    return table.concat(t)
end

-- ── long-string embed ─────────────────────────────────────────────────────────

local function longStr(s)
    local lv=0
    while s:find("]"..string.rep("=",lv).."]",1,true) do lv=lv+1 end
    local eq=string.rep("=",lv)
    return "["..eq.."["..s.."]"..eq.."]"
end

-- ── VM source builder ─────────────────────────────────────────────────────────
-- Builds the runtime VM as a plain string (no string.format with [[]] template).
-- Each line is a separate string literal concatenated with ..
-- This avoids luac5.1 parsing Lua code inside function call arguments.

local function buildVM(xorKey, decodeMap)
    -- Emit the XOR key and decode map as literals
    local xkStr = tostring(xorKey)

    -- Build decode map literal  {[wireOp]=canonOp, ...}
    local dmParts = {}
    for wire, canon in pairs(decodeMap) do
        dmParts[#dmParts+1] = "["..wire.."]="..canon
    end
    local dmLit = "{"..table.concat(dmParts,",").."}"

    -- All opcode canonical numbers referenced in the dispatch
    local function op(name) return tostring(OP[name]) end

    -- Build the VM line by line using table.concat
    -- The VM is Lua 5.1 / Luau compatible:
    --   * No goto (replaced with while+break structure)
    --   * No bit operators (~=, >> etc.)
    --   * No string.format inside long strings
    local L = {}
    local function ln(s) L[#L+1] = s end

    ln("local _sb=string.byte")
    ln("local _sc=string.char")
    ln("local _ss=string.sub")
    ln("local _fl=math.floor")
    ln("local _up=unpack or table.unpack")
    ln("local _XK="..xkStr)
    ln("local _DM="..dmLit)
    ln("")
    -- bxor
    ln("local function _bx(a,b)")
    ln("    local r,m=0,1")
    ln("    while a>0 or b>0 do")
    ln("        local ra,rb=a%2,b%2")
    ln("        if ra~=rb then r=r+m end")
    ln("        a=_fl(a/2);b=_fl(b/2);m=m*2")
    ln("    end")
    ln("    return r")
    ln("end")
    ln("")
    -- deserialiser
    ln("local function _ds(blob)")
    ln("    local pos=1")
    ln("    local function r1()")
    ln("        local v=_sb(blob,pos);pos=pos+1")
    ln("        local r,m,av,bv=0,1,v,_XK")
    ln("        while av>0 or bv>0 do")
    ln("            local ra,rb=av%2,bv%2")
    ln("            if ra~=rb then r=r+m end")
    ln("            av=_fl(av/2);bv=_fl(bv/2);m=m*2")
    ln("        end")
    ln("        return r")
    ln("    end")
    ln("    local function r2() local a=r1();local b=r1();return a*256+b end")
    ln("    local function rC()")
    ln("        local t=r1()")
    ln("        if t==0 then return nil")
    ln("        elseif t==1 then return r1()~=0")
    ln("        elseif t==2 then")
    ln("            local a,b,c,d=r1(),r1(),r1(),r1()")
    ln("            local v=a*16777216+b*65536+c*256+d")
    ln("            if v>=2147483648 then v=v-4294967296 end")
    ln("            return v")
    ln("        elseif t==3 then")
    ln("            local bs={}")
    ln("            for _=1,8 do bs[#bs+1]=r1() end")
    ln("            local lo=bs[1]+bs[2]*256+bs[3]*65536+bs[4]*16777216")
    ln("            local hi=bs[5]+bs[6]*256+bs[7]*65536+bs[8]*16777216")
    ln("            if lo==0 and hi==0 then return 0 end")
    ln("            local sg=_fl(hi/2147483648)")
    ln("            local ex=_fl(hi/1048576)%2048")
    ln("            local mh=hi%1048576")
    ln("            return((-1)^sg)*(2^(ex-1023))*((mh*4294967296+lo)/(2^52)+1)")
    ln("        elseif t==4 then")
    ln("            local ln2=r2()")
    ln("            local sv=_ss(blob,pos,pos+ln2-1);pos=pos+ln2;return sv")
    ln("        end")
    ln("    end")
    ln("    local function rI()")
    ln("        local b1,b2,b3,b4,b5,b6=r1(),r1(),r1(),r1(),r1(),r1()")
    ln("        local op=_DM[b1] or b1")
    ln("        return {op,b2,b3*256+b4,b5*256+b6}")
    ln("    end")
    ln("    local function rP()")
    ln("        local p={pa=r1(),va=r1()~=0,mr=r1(),K={},I={},P={}}")
    ln("        local nc=r2();for i=1,nc do p.K[i]=rC() end")
    ln("        local ni=r2();for i=1,ni do p.I[i]=rI() end")
    ln("        local np=r1();for i=1,np do p.P[i]=rP() end")
    ln("        return p")
    ln("    end")
    ln("    return rP()")
    ln("end")
    ln("")
    -- VM executor (recursive for closures)
    -- Uses while+break instead of goto for Lua 5.1 compatibility
    ln("local _ex")
    ln("_ex=function(proto,capSlots,env)")
    ln("    local K=proto.K;local I=proto.I;local P=proto.P")
    ln("    if not capSlots then capSlots={} end")
    ln("    local capC=0  -- next allocation slot for ALLOC_UPVAL")
    ln("    -- find max existing slot so ALLOC_UPVAL doesn't collide")
    ln("    for k,_ in pairs(capSlots) do if k>capC then capC=k end end")
    ln("    return function(...)")
    ln("        local Stk={};local args={...}")
    ln("        for i=1,proto.pa do Stk[i]=args[i] end")
    ln("        local Varg={}")
    ln("        if proto.va then")
    ln("            for i=proto.pa+1,#args do Varg[#Varg+1]=args[i] end")
    ln("        end")
    ln("        local PC=1")
    ln("        local running=true")
    ln("        local retVal=nil")
    ln("        local retMulti=false")
    ln("        while running do")
    ln("            local inst=I[PC]")
    ln("            if not inst then break end")
    ln("            local op_=inst[1];local A=inst[2]+1;local B=inst[3];local C_=inst[4]")
    ln("            PC=PC+1")
    ln("            if op_=="..op("LOADNIL").." then")
    ln("                Stk[A]=nil")
    ln("            elseif op_=="..op("LOADBOOL").." then")
    ln("                Stk[A]=(B~=0)")
    ln("            elseif op_=="..op("LOADINT").." then")
    ln("                local v=B*256+C_")
    ln("                if v>=32768 then v=v-65536 end")
    ln("                Stk[A]=v")
    ln("            elseif op_=="..op("LOADFLOAT").." then")
    ln("                Stk[A]=K[B+1]")
    ln("            elseif op_=="..op("LOADSTR").." then")
    ln("                Stk[A]=K[B+1]")
    ln("            elseif op_=="..op("MOVE").." then")
    ln("                Stk[A]=Stk[B+1]")
    ln("            elseif op_=="..op("GETGLOBAL").." then")
    ln("                Stk[A]=env[K[B+1]]")
    ln("            elseif op_=="..op("SETGLOBAL").." then")
    ln("                env[K[B+1]]=Stk[A]")
    ln("            elseif op_=="..op("GETTABLE").." then")
    ln("                Stk[A]=Stk[B+1][Stk[C_+1]]")
    ln("            elseif op_=="..op("SETTABLE").." then")
    ln("                Stk[A][Stk[B+1]]=Stk[C_+1]")
    ln("            elseif op_=="..op("NEWTABLE").." then")
    ln("                Stk[A]={}")
    ln("            elseif op_=="..op("ADD").." then")
    ln("                Stk[A]=Stk[B+1]+Stk[C_+1]")
    ln("            elseif op_=="..op("SUB").." then")
    ln("                Stk[A]=Stk[B+1]-Stk[C_+1]")
    ln("            elseif op_=="..op("MUL").." then")
    ln("                Stk[A]=Stk[B+1]*Stk[C_+1]")
    ln("            elseif op_=="..op("DIV").." then")
    ln("                Stk[A]=Stk[B+1]/Stk[C_+1]")
    ln("            elseif op_=="..op("MOD").." then")
    ln("                Stk[A]=Stk[B+1]%Stk[C_+1]")
    ln("            elseif op_=="..op("POW").." then")
    ln("                Stk[A]=Stk[B+1]^Stk[C_+1]")
    ln("            elseif op_=="..op("CONCAT").." then")
    ln("                Stk[A]=Stk[B+1]..Stk[C_+1]")
    ln("            elseif op_=="..op("LT").." then")
    ln("                Stk[A]=Stk[B+1]<Stk[C_+1]")
    ln("            elseif op_=="..op("LE").." then")
    ln("                Stk[A]=Stk[B+1]<=Stk[C_+1]")
    ln("            elseif op_=="..op("EQ").." then")
    ln("                Stk[A]=Stk[B+1]==Stk[C_+1]")
    ln("            elseif op_=="..op("NE").." then")
    ln("                Stk[A]=(Stk[B+1]~=Stk[C_+1])")
    ln("            elseif op_=="..op("GT").." then")
    ln("                Stk[A]=Stk[B+1]>Stk[C_+1]")
    ln("            elseif op_=="..op("GE").." then")
    ln("                Stk[A]=Stk[B+1]>=Stk[C_+1]")
    ln("            elseif op_=="..op("NOT").." then")
    ln("                Stk[A]=not Stk[B+1]")
    ln("            elseif op_=="..op("UNM").." then")
    ln("                Stk[A]=-Stk[B+1]")
    ln("            elseif op_=="..op("LEN").." then")
    ln("                Stk[A]=#Stk[B+1]")
    -- CALL: R[A](R[A+1..A+B]) -> results into R[A..A+C-2], C=1 means void
    ln("            elseif op_=="..op("CALL").." then")
    ln("                -- CALL A=fn B=nArgs C=nResults")
    ln("                -- Results land at Stk[A..A+C-1] (C=0 means all results)")
    ln("                local fn=Stk[A];local ca={}")
    ln("                for i=1,B do ca[i]=Stk[A+i] end")
    ln("                local res={fn(_up(ca,1,B))}")
    ln("                if C_==0 then")
    ln("                    for i=1,#res do Stk[A+i-1]=res[i] end")
    ln("                else")
    ln("                    for i=1,C_ do Stk[A+i-1]=res[i] end")
    ln("                end")
    -- CALLM: multi-return → packed table at R[C]
    ln("            elseif op_=="..op("CALLM").." then")
    ln("                local fn=Stk[A];local ca={}")
    ln("                for i=1,B do ca[i]=Stk[A+i] end")
    ln("                Stk[C_+1]={fn(_up(ca,1,B))}")
    -- VCALL: void call, discard all results
    ln("            elseif op_=="..op("VCALL").." then")
    ln("                local fn=Stk[A];local ca={}")
    ln("                for i=1,B do ca[i]=Stk[A+i] end")
    ln("                fn(_up(ca,1,B))")
    -- JMP / JMPT / JMPF  (B is 1-based instruction index)
    ln("            elseif op_=="..op("JMP").." then")
    ln("                PC=B")
    ln("            elseif op_=="..op("JMPT").." then")
    ln("                if Stk[A] then PC=B end")
    ln("            elseif op_=="..op("JMPF").." then")
    ln("                if not Stk[A] then PC=B end")
    -- RETURN: B=1 → return nothing; B=0 → return R[A..Top]; else return R[A..A+B-2]
    ln("            elseif op_=="..op("RETURN").." then")
    ln("                running=false")
    ln("                if B==1 then")
    ln("                    retVal=nil;retMulti=false")
    ln("                elseif B==0 then")
    ln("                    local rv={};local i=A")
    ln("                    while Stk[i]~=nil do rv[#rv+1]=Stk[i];i=i+1 end")
    ln("                    retVal=rv;retMulti=true")
    ln("                else")
    ln("                    local rv={}")
    ln("                    for i=A,A+B-2 do rv[#rv+1]=Stk[i] end")
    ln("                    retVal=rv;retMulti=(#rv>1)")
    ln("                end")
    -- RETURNM: return unpack of packed-results table at R[A]
    ln("            elseif op_=="..op("RETURNM").." then")
    ln("                running=false")
    ln("                local t=Stk[A]")
    ln("                retVal=(type(t)==\"table\") and t or {t}")
    ln("                retMulti=true")
    -- Upvalue ops
    ln("            elseif op_=="..op("ALLOC_UPVAL").." then")
    ln("                -- ALLOC_UPVAL A: allocate new slot in capSlots, store slot id in Stk[A]")
    ln("                capC=capC+1")
    ln("                capSlots[capC]={v=Stk[A]}")
    ln("                Stk[A]=capC  -- reg now holds the slot id")
    ln("            elseif op_=="..op("GET_UPVAL").." then")
    ln("                -- GET_UPVAL A=dst B=slotReg: Stk[A]=capSlots[Stk[B+1]].v")
    ln("                local _sid=Stk[B+1]")
    ln("                local _sl=type(_sid)=='number' and capSlots[_sid]")
    ln("                Stk[A]=_sl and _sl.v or nil")
    ln("            elseif op_=="..op("SET_UPVAL").." then")
    ln("                -- SET_UPVAL A=slotReg B=srcReg: capSlots[Stk[A]].v=Stk[B+1]")
    ln("                local _sid=Stk[A]")
    ln("                local _sl=type(_sid)=='number' and capSlots[_sid]")
    ln("                if _sl then _sl.v=Stk[B+1] end")
    ln("            elseif op_=="..op("FREE_UPVAL").." then")
    ln("                -- noop")
    -- CLOSURE: R[A] = _ex(P[B+1], upT, env)  (share upvalue table)
    ln("            elseif op_=="..op("CLOSURE").." then")
    ln("                local subP=P[B+1]")
    ln("                local childCap={}")
    ln("                for _ci=1,C_ do")
    ln("                    local capInst=I[PC]; PC=PC+1")
    ln("                    local parentReg=capInst[3]  -- B field = 0-based parent reg")
    ln("                    local parentVal=Stk[parentReg+1]")
    ln("                    -- If parentVal is a slot id in capSlots, share the box")
    ln("                    if type(parentVal)=='number' and capSlots[parentVal] then")
    ln("                        childCap[_ci]=capSlots[parentVal]")
    ln("                    else")
    ln("                        childCap[_ci]={v=parentVal}")
    ln("                    end")
    ln("                end")
    ln("                Stk[A]=_ex(subP,childCap,env)")
    -- VARARG: B=0 → pack all into table at A; else R[A..A+B-2] = vararg[1..B-1]
    ln("            elseif op_=="..op("VARARG").." then")
    ln("                if B==0 then")
    ln("                    Stk[A]={_up(Varg,1,#Varg)}")
    ln("                else")
    ln("                    for i=1,B-1 do Stk[A+i-1]=Varg[i] end")
    ln("                end")
    ln("            end")  -- end dispatch
    ln("        end")  -- end while running
    ln("        if retMulti then")
    ln("            return _up(retVal,1,#retVal)")
    ln("        elseif retVal~=nil then")
    ln("            return retVal")
    ln("        end")
    ln("    end")  -- end inner function
    ln("end")  -- end _ex
    ln("")

    return table.concat(L, "\n")
end

-- ── apply ─────────────────────────────────────────────────────────────────────

function VmifyBC:apply(ast, pipeline)

    -- Seed RNG if not already done (guards against unseeded math.random on Windows)
    math.randomseed(math.randomseed and os.time() or 0)
    -- Discard first few values (common Lua practice to get better distribution)
    math.random(); math.random(); math.random()

    -- 1. Compile AST → Proto
    local bc = BCFactory.new()
    local ok, proto = pcall(function() return bc:compile(ast) end)
    if not ok then
        logger:warn("[VmifyBC] Compilation failed: "..tostring(proto))
        logger:warn("[VmifyBC] AST unchanged — add a Vmify step as fallback")
        return ast
    end

    -- 2. XOR key + opcode shuffle
    local xorKey = (self.XorKey and self.XorKey > 0) and self.XorKey or math.random(1,254)
    local encodeMap, decodeMap
    if self.ShuffleOpcodes ~= false then
        encodeMap, decodeMap = ISA.makeOpcodeMap()
    else
        encodeMap, decodeMap = {}, {}
        for i = 0, ISA.OP_COUNT-1 do encodeMap[i]=i; decodeMap[i]=i end
    end
    local function encOp(c) return encodeMap[c] or c end

    -- 3. Serialise → double-XOR → compress
    --
    -- IMPROVEMENT 1 — Two-key blob encoding:
    --   Both XOR passes happen on the raw binary blob BEFORE LZW compression.
    --   This is critical: XOR must never be applied to the LZW text string
    --   because LZW encodes to base-36 ASCII and XOR would push bytes outside
    --   that range, corrupting the decompressor input.
    --
    --   stored in source  = lzw(blob ^ blobKey ^ rtSalt)
    --   runtime recovers  = decompress, then the inner _ds XOR (xorKey) handles
    --                        the instruction-level decode as before.
    --
    --   A reverser with only the source gets lzw(blob ^ blobKey ^ rtSalt).
    --   They need BOTH keys to recover the ISA bytecode.
    --
    local blob    = ISA.serialiseProto(proto, xorKey, encOp)
    local blobKey = math.random(1, 127)   -- first key, embedded as literal
    local rtSalt  = math.random(1, 126)   -- second key, embedded as literal
    -- ensure they differ so the double-XOR isn't a no-op
    if rtSalt == blobKey then rtSalt = (rtSalt % 126) + 1 end

    -- Apply both XOR passes to the binary blob (safe — binary stays binary)
    local encoded = xorB(xorB(blob, blobKey), rtSalt)

    -- Now LZW-compress the doubly-XOR'd binary
    local compressed = lzw(encoded)

    logger:info(string.format(
        "[VmifyBC] proto: %d instr, %d consts, %d sub-protos | blob %d B → 2xor %d B → lzw %d B",
        #proto.instrs, #proto.consts, #proto.protos,
        #blob, #encoded, #compressed))

    -- 4. Build VM source
    local vmSrc = buildVM(xorKey, decodeMap)

    -- 5. Build glue code
    --    Runtime: lzwD → xdB(blob, blobKey) → xdB(blob, rtSalt) → _ds
    --    Both keys are plain integer literals in the source.
    --    A reverser needs to find and apply both to recover the ISA stream.
    local blobLit = longStr(compressed)
    local bkLit   = tostring(blobKey)
    local saltLit = tostring(rtSalt)

    local glue = table.concat({
        "-- ZukaTech Bytecode VM entry",
        "local function _lzwD(b)",
        "    local c,d,e,f,g='','',{},256,{}",
        "    for h=0,255 do g[h]=string.char(h) end",
        "    local i=1",
        "    local function k()",
        "        local l=tonumber(string.sub(b,i,i),36);i=i+1",
        "        local m=tonumber(string.sub(b,i,i+l-1),36);i=i+l",
        "        return m",
        "    end",
        "    c=string.char(k());e[1]=c",
        "    while i<=#b do",
        "        local n=k()",
        "        if g[n] then d=g[n] else d=c..string.sub(c,1,1) end",
        "        g[f]=c..string.sub(d,1,1);e[#e+1],c,f=d,d,f+1",
        "    end",
        "    return table.concat(e)",
        "end",
        "local function _xdB(s,k)",
        "    local function _bx2(a,b)",
        "        local r,m=0,1",
        "        while a>0 or b>0 do",
        "            local ra,rb=a%2,b%2",
        "            if ra~=rb then r=r+m end",
        "            a=math.floor(a/2);b=math.floor(b/2);m=m*2",
        "        end",
        "        return r",
        "    end",
        "    local t={}",
        "    for i=1,#s do t[i]=string.char(_bx2(s:byte(i),k)%256) end",
        "    return table.concat(t)",
        "end",
        -- Decompress first, then undo both XOR passes (reverse order: salt then key)
        "local _blob=_xdB(_xdB(_lzwD("..blobLit.."),"..saltLit.."),"..bkLit..")",
        "local _proto=_ds(_blob)",
        "local _fn=_ex(_proto,nil,getfenv and getfenv() or _ENV)",
        "_fn(...)",
    }, "\n")

    local fullSrc = vmSrc .. "\n" .. glue

    -- 6. Re-parse into a ZukaTech AST so the pipeline continues normally
    local parser = Parser:new({ LuaVersion = LuaVersion.Lua51 })
    local ok2, newAst = pcall(function() return parser:parse(fullSrc) end)
    if not ok2 then
        logger:warn("[VmifyBC] Re-parse failed: "..tostring(newAst))
        -- Dump first 300 chars for diagnosis
        logger:warn("[VmifyBC] Source head: "..fullSrc:sub(1,300))
        return ast
    end

    return newAst
end

return VmifyBC