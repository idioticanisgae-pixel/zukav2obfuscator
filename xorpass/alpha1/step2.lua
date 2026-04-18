local unpack = unpack or table.unpack
math.randomseed(os.time())
math.random(); math.random(); math.random()
local function randomName(min, max)
    min = min or 8; max = max or 12
    local len = math.random(min, max)
    local charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local t = {}
    for _ = 1, len do
        local i = math.random(1, #charset)
        t[#t+1] = charset:sub(i,i)
    end
    return table.concat(t)
end
local reserved_words = {
    ["if"]=true,["then"]=true,["else"]=true,["elseif"]=true,["end"]=true,
    ["for"]=true,["while"]=true,["do"]=true,["repeat"]=true,["until"]=true,
    ["function"]=true,["local"]=true,["return"]=true,["break"]=true,
    ["and"]=true,["or"]=true,["not"]=true,["in"]=true,["nil"]=true,
    ["true"]=true,["false"]=true,["continue"]=true,
}
local ISA = {}
ISA.OP = {
    LOADNIL=0, LOADBOOL=1, LOADINT=2, LOADFLOAT=3, LOADSTR=4,
    MOVE=5, GETGLOBAL=6, SETGLOBAL=7, GETTABLE=8, SETTABLE=9,
    NEWTABLE=10, ADD=11, SUB=12, MUL=13, DIV=14, MOD=15, POW=16,
    CONCAT=17, LT=18, LE=19, EQ=20, NE=21, GT=22, GE=23,
    NOT=24, UNM=25, LEN=26, CALL=27, CALLM=28, VCALL=29,
    JMP=30, JMPT=31, JMPF=32, RETURN=33, RETURNM=34,
    ALLOC_UPVAL=35, GET_UPVAL=36, SET_UPVAL=37, FREE_UPVAL=38,
    CLOSURE=39, VARARG=40,
}
ISA.OP_COUNT = 41
function ISA.makeOpcodeMap()
    local canon = {}
    for k,v in pairs(ISA.OP) do canon[v] = k end
    local pool = {}
    for i = 0, ISA.OP_COUNT-1 do pool[i+1] = i end
    for i = ISA.OP_COUNT, 2, -1 do
        local j = math.random(1, i)
        pool[i], pool[j] = pool[j], pool[i]
    end
    local enc, dec = {}, {}
    for canon_id = 0, ISA.OP_COUNT-1 do
        local wire = pool[canon_id+1]
        enc[canon_id] = wire
        dec[wire] = canon_id
    end
    return enc, dec
end
function ISA.makeXorStream(seed)
    local s = seed % 4294967296
    return function()
        s = (s * 1664525 + 1013904223) % 4294967296
        return s % 256
    end
end
local function bx(a, b)
    local r, m = 0, 1
    while a > 0 or b > 0 do
        local ra, rb = a%2, b%2
        if ra ~= rb then r = r+m end
        a = math.floor(a/2); b = math.floor(b/2); m = m*2
    end
    return r % 256
end
function ISA.serialiseProto(proto, xorSeed, encOp, depth)
    depth = depth or 0
    local function protoSeed(d)
        local lo = bx(xorSeed%256, (math.floor(d*0x9E))%256)
        return (lo + math.floor(xorSeed/256)*256) % 4294967296
    end
    local bytes = {}
    local function wb(v)  bytes[#bytes+1] = string.char(v % 256) end
    local function w2(v)  wb(math.floor(v/256)); wb(v%256) end
    local function w4(v)
        wb(math.floor(v/16777216)%256); wb(math.floor(v/65536)%256)
        wb(math.floor(v/256)%256);      wb(v%256)
    end
    wb(proto.params or 0)
    wb(proto.is_vararg and 1 or 0)
    wb(proto.max_reg or 0)
    local consts = proto.consts or {}
    w2(#consts)
    for _, v in ipairs(consts) do
        local t = type(v)
        if v == nil then
            wb(0)
        elseif t == "boolean" then
            wb(1); wb(v and 1 or 0)
        elseif t == "number" then
            if math.floor(v) == v and v >= -2147483648 and v <= 2147483647 then
                wb(2)
                local n = v < 0 and (v + 4294967296) or v
                w4(n)
            else
                wb(3)
                local sign = v < 0 and 1 or 0
                if v < 0 then v = -v end
                local exp, frac = 0, 0
                if v == 0 then
                elseif v == math.huge then
                    exp = 2047
                else
                    exp = math.floor(math.log(v) / math.log(2))
                    frac = v / (2^exp) - 1
                    exp = exp + 1023
                end
                local hi = sign * 2147483648 + exp * 1048576 + math.floor(frac * 1048576)
                local lo_f = (frac * 1048576 - math.floor(frac * 1048576)) * 4294967296
                local lo = math.floor(lo_f)
                wb(lo%256); wb(math.floor(lo/256)%256)
                wb(math.floor(lo/65536)%256); wb(math.floor(lo/16777216)%256)
                wb(hi%256); wb(math.floor(hi/256)%256)
                wb(math.floor(hi/65536)%256); wb(math.floor(hi/16777216)%256)
            end
        elseif t == "string" then
            wb(4); w2(#v)
            for i = 1, #v do wb(v:byte(i)) end
        end
    end
    local instrs = proto.instrs or {}
    w2(#instrs)
    local st = ISA.makeXorStream(protoSeed(depth))
    for _, ins in ipairs(instrs) do
        local op, a, b, c = ins[1], ins[2] or 0, ins[3] or 0, ins[4] or 0
        local wire_op = encOp and encOp(op) or op
        local bh, bl = math.floor(b/256), b%256
        local ch, cl = math.floor(c/256), c%256
        local s1,s2,s3,s4,s5,s6 = st(),st(),st(),st(),st(),st()
        wb(bx(wire_op, s1)); wb(bx(a, s2)); wb(bx(bh, s3))
        wb(bx(bl, s4));      wb(bx(ch, s5)); wb(bx(cl, s6))
    end
    local protos = proto.protos or {}
    wb(#protos)
    for _, sub in ipairs(protos) do
        local subBytes = ISA.serialiseProto(sub, xorSeed, encOp, depth+1)
        for i = 1, #subBytes do bytes[#bytes+1] = subBytes:sub(i,i) end
    end
    return table.concat(bytes)
end
local function renameVariables(code, minLen, maxLen)
    minLen = minLen or 8; maxLen = maxLen or 12
    local usedNames = {}
    local function genUnique()
        local name
        repeat name = randomName(minLen, maxLen)
        until not usedNames[name] and not reserved_words[name]
        usedNames[name] = true
        return name
    end
    local varMap = {}
    for decl in code:gmatch("local%s+([%w_][%w_,]*)%s*=") do
        for v in decl:gmatch("[%w_]+") do
            if not reserved_words[v] and not varMap[v] then
                varMap[v] = genUnique()
            end
        end
    end
    for v in code:gmatch("local%s+function%s+([%w_]+)") do
        if not reserved_words[v] and not varMap[v] then
            varMap[v] = genUnique()
        end
    end
    for decl in code:gmatch("local%s+([%w_][%w_,%s]-)%s*\n") do
        for v in decl:gmatch("[%w_]+") do
            if not reserved_words[v] and not varMap[v] then
                varMap[v] = genUnique()
            end
        end
    end
    local function replaceOutside(src, target, repl)
        local ph = "\xFE\xFF_ZPH_\xFE\xFF"
        local protected = src:gsub('(["\'])(.-)%1', function(q, c)
            c = c:gsub(target, ph)
            return q..c..q
        end)
        local result = protected:gsub('(%f[%w_])'..target..'(%f[^%w_])', repl)
        return result:gsub(ph, target)
    end
    for orig, new in pairs(varMap) do
        code = replaceOutside(code, orig, new)
    end
    local globals = {
        "math.random", "math.floor", "string.byte", "string.char",
        "string.sub", "table.concat", "table.insert", "tostring", "tonumber",
        "type", "pairs", "ipairs", "pcall", "error", "assert",
        "game", "workspace", "script",
    }
    local aliases = {}
    local aliasDefs = {}
    for _, g in ipairs(globals) do
        if code:find(g, 1, true) then
            local alias = genUnique()
            aliases[g] = alias
            aliasDefs[#aliasDefs+1] = "local "..alias.."="..g
        end
    end
    if #aliasDefs > 0 then
        code = table.concat(aliasDefs, "\n").."\n"..code
        for g, alias in pairs(aliases) do
            code = replaceOutside(code, g, alias)
        end
    end
    return code
end
local stubs = {
    [[local _e,_o,_d="%s",%d,{}
for _i=1,#_e,2 do
    local _b=tonumber(_e:sub(_i,_i+1),16)
    _b=(_b-_o+256)%%256
    _d[#_d+1]=string.char(_b)
end
assert(load(table.concat(_d)))(  )]],
    [[local _h,_k="%s",%d
local _t={}
local _s=string
for _i=1,#_h,2 do
    _t[#_t+1]=_s.char((tonumber(_s.sub(_h,_i,_i+1),16)-_k+256)%%256)
end
;(assert(load(table.concat(_t))))(  )]],
    [[local _blob,_off,_buf="%s",%d,{}
local _idx=1
while _idx<=#_blob do
    local _v=tonumber(_blob:sub(_idx,_idx+1),16)
    _buf[#_buf+1]=string.char((_v-_off+256)%%256)
    _idx=_idx+2
end
local _fn=assert(load(table.concat(_buf)))
_fn(  )]],
}
local function encodeBytecode(code)
    local offset = math.random(1, 255)
    local hex = {}
    for i = 1, #code do
        hex[i] = string.format("%02X", (code:byte(i) + offset) % 256)
    end
    local encoded = table.concat(hex)
    local shape = stubs[math.random(1, #stubs)]
    return string.format(shape, encoded, offset)
end
local function buildXorTableCode(code)
    local function makePermutation()
        local p = {}
        for i = 1, 16 do p[i] = i-1 end
        for i = 16, 2, -1 do
            local j = math.random(1, i)
            p[i], p[j] = p[j], p[i]
        end
        return p
    end
    local rowPerm = makePermutation()
    local colPerm = makePermutation()
    local entries = {}
    for r = 0, 15 do
        for c = 0, 15 do
            local storeRow = rowPerm[r+1]
            local storeCol = colPerm[c+1]
            entries[storeRow * 16 + storeCol + 1] = r ~= c and
                (function()
                    local v = 0
                    local ra, ca = r, c
                    local m = 1
                    while ra > 0 or ca > 0 do
                        if (ra%2) ~= (ca%2) then v = v+m end
                        ra = math.floor(ra/2); ca = math.floor(ca/2); m = m*2
                    end
                    return v
                end)() or 0
        end
    end
    local tblName = randomName()
    local fnName  = randomName()
    local rPName  = randomName()
    local cPName  = randomName()
    local tblLit = "{"..table.concat(entries, ",").."}"
    local rPLit  = "{"..table.concat(rowPerm, ",").."}"
    local cPLit  = "{"..table.concat(colPerm, ",").."}"
    local header = string.format([[
local %s=%s
local %s=%s
local %s=%s
local function %s(a,b)
    local function _nx(x,y)
        local r=0
        local ri=%s[math.floor(x/16)+1]
        local ci=%s[y%%16+1]
        r=r+%s[ri*16+ci+1]
        ri=%s[x%%16+1]
        ci=%s[math.floor(y/16)+1]
        r=r+%s[ri*16+ci+1]*16
        return r
    end
    local r=0
    local aa,bb=a,b
    while aa>0 or bb>0 do
        r=r+_nx(aa%%256,bb%%256)
        aa=math.floor(aa/256);bb=math.floor(bb/256)
    end
    return r
end
]], tblName, tblLit,
    rPName, rPLit,
    cPName, cPLit,
    fnName,
    rPName, cPName, tblName,
    rPName, cPName, tblName)
    local result = code:gsub("bit32%.bxor%s*%(([^,%)]+),([^%)]+)%)",
        function(a, b) return fnName.."("..a..","..b..")" end)
    return header .. result
end
local FNV_PRIME  = 16777619
local FNV_OFFSET = 2166136261
local function fnv1a(s)
    local h = FNV_OFFSET
    for i = 1, #s do
        local a, b = h, s:byte(i)
        local r, m = 0, 1
        while a > 0 or b > 0 do
            if (a%2) ~= (b%2) then r = r+m end
            a = math.floor(a/2); b = math.floor(b/2); m = m*2
        end
        h = (r * FNV_PRIME) % 4294967296
    end
    return h
end
local function addIntegrityHash(code, sampleSize)
    sampleSize = sampleSize or 12
    local strings = {}
    for s in code:gmatch('"([^"]*)"') do strings[#strings+1] = s end
    for s in code:gmatch("'([^']*)'") do strings[#strings+1] = s end
    if #strings < 2 then return code end
    local sample = {}
    local n = math.min(sampleSize, #strings)
    local used = {}
    while #sample < n do
        local idx = math.random(1, #strings)
        if not used[idx] then
            used[idx] = true
            sample[#sample+1] = strings[idx]
        end
    end
    local combined = table.concat(sample, "\0")
    local expected = fnv1a(combined)
    local mask = math.random(1, 0x7FFFFFFF)
    local maskedExpected = math.floor(expected) ~= 0 and
        (expected % 4294967296) or 0
    local maskLit = tostring(mask)
    local expectedLit = tostring(maskedExpected)
    local hFn   = randomName()
    local sFn   = randomName()
    local sLit  = '"'..combined:gsub('"', '\\"')..'"'
    local fakeFn = randomName()
    local fakeCode = string.format([[
local function %s()
    while true do task.wait(math.huge) end
end
]], fakeFn)
    local hashCode = string.format([[
local function %s(s)
    local h=%s
    local p=%s
    for i=1,#s do
        local a,b=h,s:byte(i)
        local r,m=0,1
        while a>0 or b>0 do
            if (a%%2)~=(b%%2) then r=r+m end
            a=math.floor(a/2);b=math.floor(b/2);m=m*2
        end
        h=(r*p)%%4294967296
    end
    return h
end
if %s(%s)~=%s then %s() end
]], hFn, tostring(FNV_OFFSET), tostring(FNV_PRIME),
    hFn, sLit, expectedLit,
    fakeFn)
    return fakeCode .. hashCode .. code
end
local function bxorLua(a, b)
    local r, m = 0, 1
    while a > 0 or b > 0 do
        if (a%2) ~= (b%2) then r = r+m end
        a = math.floor(a/2); b = math.floor(b/2); m = m*2
    end
    return r
end
local function xorBytes(s, k)
    local t = {}
    for i = 1, #s do t[i] = string.char(bxorLua(s:byte(i), k) % 256) end
    return table.concat(t)
end
local function b36(n)
    if n == 0 then return "0" end
    local C = "0123456789abcdefghijklmnopqrstuvwxyz"
    local s = ""
    while n > 0 do
        s = C:sub(n%36+1, n%36+1)..s
        n = math.floor(n/36)
    end
    return s
end
local function eCode(n) local s = b36(n); return b36(#s)..s end
local function lzw(inp)
    local d, ds = {}, 256
    for i = 0, 255 do d[string.char(i)] = i end
    local w, o = "", {}
    for i = 1, #inp do
        local c = inp:sub(i,i); local wc = w..c
        if d[wc] then w = wc
        else o[#o+1] = eCode(d[w]); d[wc] = ds; ds = ds+1; w = c end
    end
    if w ~= "" then o[#o+1] = eCode(d[w]) end
    return table.concat(o)
end
local function longStr(s)
    local lv = 0
    while s:find("]"..string.rep("=", lv).."]", 1, true) do lv = lv+1 end
    local eq = string.rep("=", lv)
    return "["..eq.."["..s.."]"..eq.."]"
end
local function buildVM(xorSeed, decodeMap)
    local function op(name) return tostring(ISA.OP[name]) end
    local dmParts = {}
    for wire, canon in pairs(decodeMap) do
        dmParts[#dmParts+1] = "["..wire.."]="..canon
    end
    local dmLit = "{"..table.concat(dmParts, ",").."}"
    local L = {}
    local function ln(s) L[#L+1] = s end
    ln("local _sb=string.byte")
    ln("local _ss=string.sub")
    ln("local _fl=math.floor")
    ln("local _up=unpack or table.unpack")
    ln("local _XS="..tostring(xorSeed))
    ln("local _DM="..dmLit)
    ln("")
    ln("local function _bx(a,b)")
    ln("    local r,m=0,1")
    ln("    while a>0 or b>0 do")
    ln("        local ra,rb=a%2,b%2")
    ln("        if ra~=rb then r=r+m end")
    ln("        a=_fl(a/2);b=_fl(b/2);m=m*2")
    ln("    end")
    ln("    return r%256")
    ln("end")
    ln("")
    ln("local function _mkS(seed)")
    ln("    local s=seed%4294967296")
    ln("    return function()")
    ln("        s=(s*1664525+1013904223)%4294967296")
    ln("        return s%256")
    ln("    end")
    ln("end")
    ln("")
    ln("local function _pSeed(depth)")
    ln("    local lo=_bx(_XS%256,(_fl(depth*0x9E))%256)")
    ln("    return (lo+_fl(_XS/256)*256)%4294967296")
    ln("end")
    ln("")
    ln("local _ds")
    ln("_ds=function(blob)")
    ln("    local pos=1")
    ln("    local function rb() local v=_sb(blob,pos);pos=pos+1;return v end")
    ln("    local function r2() return rb()*256+rb() end")
    ln("    local function rC()")
    ln("        local t=rb()")
    ln("        if t==0 then return nil")
    ln("        elseif t==1 then return rb()~=0")
    ln("        elseif t==2 then")
    ln("            local a,b,c,d=rb(),rb(),rb(),rb()")
    ln("            local v=a*16777216+b*65536+c*256+d")
    ln("            if v>=2147483648 then v=v-4294967296 end")
    ln("            return v")
    ln("        elseif t==3 then")
    ln("            local bs={}")
    ln("            for _=1,8 do bs[#bs+1]=rb() end")
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
    ln("    local function rP(depth)")
    ln("        local p={pa=rb(),va=rb()~=0,mr=rb(),K={},I={},P={}}")
    ln("        local nc=r2();for i=1,nc do p.K[i]=rC() end")
    ln("        local ni=r2()")
    ln("        local st=_mkS(_pSeed(depth))")
    ln("        for i=1,ni do")
    ln("            local s1,s2,s3,s4,s5,s6=st(),st(),st(),st(),st(),st()")
    ln("            local b1=_bx(_sb(blob,pos),  s1)")
    ln("            local b2=_bx(_sb(blob,pos+1),s2)")
    ln("            local b3=_bx(_sb(blob,pos+2),s3)")
    ln("            local b4=_bx(_sb(blob,pos+3),s4)")
    ln("            local b5=_bx(_sb(blob,pos+4),s5)")
    ln("            local b6=_bx(_sb(blob,pos+5),s6)")
    ln("            pos=pos+6")
    ln("            p.I[i]={_DM[b1] or b1,b2,b3*256+b4,b5*256+b6}")
    ln("        end")
    ln("        local np=rb();for i=1,np do p.P[i]=rP(depth+1) end")
    ln("        return p")
    ln("    end")
    ln("    return rP(0)")
    ln("end")
    ln("")
    local handlers = {
        { op("LOADNIL"),   "Stk[A]=nil" },
        { op("LOADBOOL"),  "Stk[A]=(B~=0)" },
        { op("LOADINT"),   "local v=B*65536+C_","if v>=2147483648 then v=v-4294967296 end","Stk[A]=v" },
        { op("LOADFLOAT"), "Stk[A]=K[B+1]" },
        { op("LOADSTR"),   "Stk[A]=K[B+1]" },
        { op("MOVE"),      "Stk[A]=Stk[B]" },
        { op("GETGLOBAL"), "Stk[A]=env[K[B+1]]" },
        { op("SETGLOBAL"), "env[K[B+1]]=Stk[A]" },
        { op("GETTABLE"),  "Stk[A]=Stk[B][Stk[C_]]" },
        { op("SETTABLE"),  "Stk[A][Stk[B]]=Stk[C_]" },
        { op("NEWTABLE"),  "Stk[A]={}" },
        { op("ADD"),   "Stk[A]=Stk[B]+Stk[C_]" },
        { op("SUB"),   "Stk[A]=Stk[B]-Stk[C_]" },
        { op("MUL"),   "Stk[A]=Stk[B]*Stk[C_]" },
        { op("DIV"),   "Stk[A]=Stk[B]/Stk[C_]" },
        { op("MOD"),   "Stk[A]=Stk[B]%Stk[C_]" },
        { op("POW"),   "Stk[A]=Stk[B]^Stk[C_]" },
        { op("CONCAT"),"Stk[A]=Stk[B]..Stk[C_]" },
        { op("LT"),    "Stk[A]=Stk[B]<Stk[C_]" },
        { op("LE"),    "Stk[A]=Stk[B]<=Stk[C_]" },
        { op("EQ"),    "Stk[A]=Stk[B]==Stk[C_]" },
        { op("NE"),    "Stk[A]=(Stk[B]~=Stk[C_])" },
        { op("GT"),    "Stk[A]=Stk[B]>Stk[C_]" },
        { op("GE"),    "Stk[A]=Stk[B]>=Stk[C_]" },
        { op("NOT"),   "Stk[A]=not Stk[B]" },
        { op("UNM"),   "Stk[A]=-Stk[B]" },
        { op("LEN"),   "Stk[A]=#Stk[B]" },
        { op("CALL"),
            "local fn=Stk[A];local ca={}",
            "if B==0 then local _t=Stk[A+1]",
            "    if type(_t)=='table' then for _i=1,#_t do ca[_i]=_t[_i] end",
            "    elseif _t~=nil then ca[1]=_t end",
            "else for i=1,B do ca[i]=Stk[A+i] end end",
            "local _cn=#ca;if _cn>200 then _cn=200 end",
            "local res={fn(_up(ca,1,_cn))}",
            "if C_==0 then for i=1,#res do Stk[A+i-1]=res[i] end",
            "else for i=1,C_ do Stk[A+i-1]=res[i] end end" },
        { op("VCALL"),
            "local fn=Stk[A];local ca={}",
            "for i=1,B do ca[i]=Stk[A+i] end",
            "local _cn=#ca;if _cn>200 then _cn=200 end",
            "fn(_up(ca,1,_cn))" },
        { op("JMP"),    "return B,nil,nil,nil,nil" },
        { op("JMPT"),   "if Stk[A] then return B,nil,nil,nil,nil end" },
        { op("JMPF"),   "if not Stk[A] then return B,nil,nil,nil,nil end" },
        { op("RETURN"),
            "local rv2,rm2",
            "if B==1 then rv2=nil;rm2=false",
            "elseif B==0 then",
            "    local rv={};local i=A",
            "    while i<=proto.mr and Stk[i]~=nil do rv[#rv+1]=Stk[i];i=i+1 end",
            "    rv2=rv;rm2=true",
            "else",
            "    local rv={}",
            "    for i=A,A+B-2 do rv[#rv+1]=Stk[i] end",
            "    rv2=rv;rm2=(#rv>1)",
            "end",
            "return nil,false,rv2,rm2,nil" },
        { op("ALLOC_UPVAL"),
            "capC=capC+1","capSlots[capC]={v=Stk[A]}",
            "Stk[A]=capC","return nil,nil,nil,nil,capC" },
        { op("GET_UPVAL"),
            "local _sid=Stk[B]",
            "local _sl=type(_sid)=='number' and capSlots[_sid]",
            "Stk[A]=_sl and _sl.v or nil" },
        { op("SET_UPVAL"),
            "local _sid=Stk[A]",
            "local _sl=type(_sid)=='number' and capSlots[_sid]",
            "if _sl then _sl.v=Stk[B] end" },
        { op("FREE_UPVAL"), "" },
        { op("CLOSURE"),
            "local subP=P[B+1]","local childCap={}","local nPC=PC",
            "for _ci=1,C_ do",
            "    local capInst=I[nPC];nPC=nPC+1",
            "    local parentReg=capInst[3]",
            "    local parentVal=Stk[parentReg]",
            "    if type(parentVal)=='number' and capSlots[parentVal] then",
            "        childCap[_ci]=capSlots[parentVal]",
            "    else childCap[_ci]={v=parentVal} end",
            "end",
            "Stk[A]=_ex(subP,childCap,env)",
            "return nPC,nil,nil,nil,nil" },
        { op("VARARG"),
            "if B==0 then Stk[A]={_up(Varg,1,#Varg)}",
            "else for i=1,B-1 do Stk[A+i-1]=Varg[i] end end" },
    }
    for i = #handlers, 2, -1 do
        local j = math.random(1, i)
        handlers[i], handlers[j] = handlers[j], handlers[i]
    end
    local junkBodies = {{"Stk[A]=Stk[A]"},{"local _z=B+C_"},{"local _z=A*B"},{""}}
    for _ = 1, math.random(8, 20) do
        local fakeId = tostring(math.random(ISA.OP_COUNT, 254))
        local body = junkBodies[math.random(1, #junkBodies)]
        local h = {fakeId}
        for _, bl in ipairs(body) do h[#h+1] = bl end
        table.insert(handlers, math.random(1, #handlers+1), h)
    end
    ln("local _ex")
    ln("")
    ln("local _DT={}")
    for _, h in ipairs(handlers) do
        local bodyLines = {}
        for i = 2, #h do
            if h[i] ~= "" then bodyLines[#bodyLines+1] = "    "..h[i] end
        end
        if #bodyLines == 0 then
            ln("_DT["..h[1].."]=function(Stk,K,I,P,A,B,C_,proto,PC,capSlots,capC,Varg,env) end")
        else
            ln("_DT["..h[1].."]=function(Stk,K,I,P,A,B,C_,proto,PC,capSlots,capC,Varg,env)")
            for _, bl in ipairs(bodyLines) do ln(bl) end
            ln("end")
        end
    end
    ln("")
    ln("_ex=function(proto,capSlots,env)")
    ln("    local K=proto.K;local I=proto.I;local P=proto.P")
    ln("    if not capSlots then capSlots={} end")
    ln("    local capC=0")
    ln("    for k,_ in pairs(capSlots) do if k>capC then capC=k end end")
    ln("    return function(...)")
    ln("        local Stk={};local args={...}")
    ln("        for i=0,proto.pa-1 do Stk[i]=args[i+1] end")
    ln("        local Varg={}")
    ln("        if proto.va then")
    ln("            for i=proto.pa+1,#args do Varg[#Varg+1]=args[i] end")
    ln("        end")
    ln("        local PC=1;local running=true;local retVal=nil;local retMulti=false")
    ln("        while running do")
    ln("            local inst=I[PC]")
    ln("            if not inst then break end")
    ln("            local op_=inst[1];local A=inst[2];local B=inst[3];local C_=inst[4]")
    ln("            PC=PC+1")
    ln("            local _h=_DT[op_]")
    ln("            if _h then")
    ln("                local r1,r2,r3,r4,r5=_h(Stk,K,I,P,A,B,C_,proto,PC,capSlots,capC,Varg,env)")
    ln("                if r1~=nil then PC=r1 end")
    ln("                if r2~=nil then running=r2 end")
    ln("                if r3~=nil or r2==false then retVal=r3 end")
    ln("                if r4~=nil then retMulti=r4 end")
    ln("                if r5~=nil then capC=r5 end")
    ln("            end")
    ln("        end")
    ln("        if retMulti then")
    ln("            local _rn=#retVal;if _rn>200 then _rn=200 end")
    ln("            return _up(retVal,1,_rn)")
    ln("        elseif retVal~=nil then")
    ln("            return retVal")
    ln("        end")
    ln("    end")
    ln("end")
    ln("")
    return table.concat(L, "\n")
end
local function vmifySource(code)
    local bc = code
    local blobKey = math.random(1, 127)
    local rtSalt  = math.random(1, 126)
    if rtSalt == blobKey then rtSalt = (rtSalt % 126) + 1 end
    local encoded = xorBytes(xorBytes(bc, blobKey), rtSalt)
    local compressed = lzw(encoded)
    local blobLit = longStr(compressed)
    local glue_final = string.format([[
local function _lzwD(b)
    local c,d,e,f,g='','',{},256,{}
    for h=0,255 do g[h]=string.char(h) end
    local i=1
    local function k()
        local l=tonumber(string.sub(b,i,i),36);i=i+1
        local m=tonumber(string.sub(b,i,i+l-1),36);i=i+l
        return m
    end
    c=string.char(k());e[1]=c
    while i<=#b do
        local n=k()
        if g[n] then d=g[n] else d=c..string.sub(c,1,1) end
        g[f]=c..string.sub(d,1,1);e[#e+1],c,f=d,d,f+1
    end
    return table.concat(e)
end
local function _xdB(s,k2)
    local function _bx2(a,b2)
        local r,m=0,1
        while a>0 or b2>0 do
            local ra,rb=a%%2,b2%%2
            if ra~=rb then r=r+m end
            a=math.floor(a/2);b2=math.floor(b2/2);m=m*2
        end
        return r
    end
    local t={}
    for i=1,#s do t[i]=string.char(_bx2(s:byte(i),k2)%%256) end
    return table.concat(t)
end
local _rawsrc=_xdB(_xdB(_lzwD(%s),%d),%d)
local _fn=assert(loadstring and loadstring(_rawsrc) or load(_rawsrc))
_fn(...)
]], blobLit, rtSalt, blobKey)
    return glue_final
end
local M = {}
function M.obfuscate(source, opts)
    opts = opts or {}
    local doVm     = opts.VmifyBC ~= false
    local doRename = opts.VariableRenamer ~= false
    local doBC     = opts.BytecodeEncoder
    local doXor    = opts.XorTable ~= false
    local doHash   = opts.IntegrityHash ~= false
    local code = source
    if doRename then
        code = renameVariables(code,
            opts.RenameMinLen or 8,
            opts.RenameMaxLen or 12)
    end
    if doXor then
        code = buildXorTableCode(code)
    end
    if doHash then
        code = addIntegrityHash(code, opts.IntegritySampleSize or 12)
    end
    if doVm then
        local vmResult, err = vmifySource(code)
        if vmResult then
            code = vmResult
        else
            io.stderr:write("[Obfuscator] VmifyBC failed: "..tostring(err).."\n")
            io.stderr:write("[Obfuscator] Falling back to BytecodeEncoder\n")
            doBC = true
        end
    end
    if doBC and not doVm then
        local bcResult, err = encodeBytecode(code)
        if bcResult then
            code = bcResult
        else
            io.stderr:write("[Obfuscator] BytecodeEncoder failed: "..tostring(err).."\n")
        end
    end
    return code
end
if arg and arg[1] then
    local inputFile = arg[1]
    if not inputFile then
        print("Usage: lua obfuscator.lua <input.lua> [output.lua]")
        print("")
        print("Options (set via env or edit opts table in script):")
        print("  Default: VmifyBC + VariableRenamer + XorTable + IntegrityHash")
        os.exit(1)
    end
    local f = io.open(inputFile, "r")
    if not f then
        print("Error: cannot open '"..inputFile.."'")
        os.exit(1)
    end
    local source = f:read("*a")
    f:close()
    io.stderr:write("[Obfuscator] Processing: "..inputFile.."\n")
    local result = M.obfuscate(source, {
        VmifyBC         = true,
        VariableRenamer = true,
        BytecodeEncoder = false,
        XorTable        = true,
        IntegrityHash   = true,
    })
    local outputFile = arg[2] or inputFile:gsub("%.lua$", "_obf.lua")
    local out = io.open(outputFile, "w")
    if not out then
        print("Error: cannot write '"..outputFile.."'")
        os.exit(1)
    end
    out:write(result)
    out:close()
    io.stderr:write("[Obfuscator] Done → "..outputFile.."\n")
    io.stderr:write("[Obfuscator] Output size: "..#result.." bytes\n")
end
return M