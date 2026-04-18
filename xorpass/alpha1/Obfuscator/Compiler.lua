--compiler

local ISA     = require("isa")
local Ast     = require("ast")
local Scope   = require("scope")
local logger  = require("logger")

local AstKind = Ast.AstKind
local OP      = ISA.OP
local unpack  = unpack or table.unpack

-- ── helpers ───────────────────────────────────────────────────────────────────

local function lookupify(t)
    local r = {}
    for _, v in ipairs(t) do r[v] = true end
    return r
end

local BIN_OP_MAP = {
    [AstKind.AddExpression]              = OP.ADD,
    [AstKind.SubExpression]              = OP.SUB,
    [AstKind.MulExpression]              = OP.MUL,
    [AstKind.DivExpression]              = OP.DIV,
    [AstKind.ModExpression]              = OP.MOD,
    [AstKind.PowExpression]              = OP.POW,
    [AstKind.StrCatExpression]           = OP.CONCAT,
    [AstKind.LessThanExpression]         = OP.LT,
    [AstKind.LessThanOrEqualsExpression] = OP.LE,
    [AstKind.EqualsExpression]           = OP.EQ,
    [AstKind.NotEqualsExpression]        = OP.NE,
    [AstKind.GreaterThanExpression]      = OP.GT,
    [AstKind.GreaterThanOrEqualsExpression] = OP.GE,
}

-- ── BytecodeCompiler ──────────────────────────────────────────────────────────

local BC = {}
BC.__index = BC

function BC:new()
    local o = setmetatable({}, BC)
    -- Sentinel values (unique per compiler instance)
    o.RETURN_ALL = {}
    o.VAR_REG    = {}   -- tag for variable-lifetime registers
    return o
end

-- ── Proto builder ─────────────────────────────────────────────────────────────
-- Each function compiles into a "ProtoCtx" (proto context).
-- We use a simple ProtoCtx object to accumulate instructions, consts, sub-protos.

function BC:newProto(params, isVararg)
    return {
        params    = params or 0,
        is_vararg = isVararg or false,
        max_reg   = 0,
        consts    = {},       -- list of constant values
        constMap  = {},       -- value -> index  (for dedup)
        instrs    = {},       -- list of {op,a,b,c}
        protos    = {},       -- nested ProtoCtx
        -- working state during compilation
        regNext   = 0,        -- next free temp register
        maxRegSeen= 0,
    }
end

function BC:addConst(proto, value)
    local key
    if type(value) == "number" then
        key = "n:" .. tostring(value)
    elseif type(value) == "string" then
        key = "s:" .. value
    elseif type(value) == "boolean" then
        key = "b:" .. tostring(value)
    else
        key = "nil"
    end
    if proto.constMap[key] then
        return proto.constMap[key] - 1  -- 0-indexed
    end
    local idx = #proto.consts + 1
    proto.consts[idx] = value
    proto.constMap[key] = idx
    return idx - 1  -- 0-indexed
end

function BC:emit(proto, op, a, b, c)
    a = a or 0; b = b or 0; c = c or 0
    proto.instrs[#proto.instrs + 1] = {op, a, b, c}
    if a > proto.maxRegSeen then proto.maxRegSeen = a end
    return #proto.instrs  -- 1-indexed instruction number
end

-- Emit a placeholder JMP and return its index so we can patch it later
function BC:emitJmp(proto, op, a)
    return self:emit(proto, op, a or 0, 0xFFFF, 0)
end

-- Patch a previously emitted JMP's B operand with the current instruction count
function BC:patchJmp(proto, instrIdx, target)
    proto.instrs[instrIdx][3] = target
end

-- Allocate a temp register
function BC:allocReg(proto)
    local r = proto.regNext
    proto.regNext = proto.regNext + 1
    if proto.regNext > proto.maxRegSeen then proto.maxRegSeen = proto.regNext end
    return r
end

function BC:freeReg(proto, r)
    -- Simple: if r is the top reg, pop it
    if r == proto.regNext - 1 then
        proto.regNext = proto.regNext - 1
    end
    -- Otherwise we leave gaps (handled by max_reg sizing)
end

-- ── compile() — entry point ───────────────────────────────────────────────────

function BC:compile(ast)
    -- Walk AST to identify upvalues (same logic as compiler.lua)
    self.upvalVars = {}
    self.scopeFuncDepths = {}

    local varAccessKinds = lookupify{
        AstKind.AssignmentVariable,
        AstKind.VariableExpression,
        AstKind.FunctionDeclaration,
        AstKind.LocalFunctionDeclaration,
    }
    local funcKinds = lookupify{
        AstKind.FunctionDeclaration,
        AstKind.LocalFunctionDeclaration,
        AstKind.FunctionLiteralExpression,
        AstKind.TopNode,
    }

    visitast(ast, function(node, data)
        if node.kind == AstKind.Block then
            node.scope.__depth = data.functionData.depth
        end
        if varAccessKinds[node.kind] and not node.scope.isGlobal then
            if node.scope.__depth < data.functionData.depth then
                self:markUpvalue(node.scope, node.id)
            end
        end
    end, nil, nil)

    -- Compile the top-level as a vararg proto
    local proto = self:compileFunction(ast, nil, 0, true)
    proto.is_vararg = true
    proto.params    = 0
    proto.max_reg   = proto.maxRegSeen + 1
    return proto
end

function BC:markUpvalue(scope, id)
    if not self.upvalVars[scope] then self.upvalVars[scope] = {} end
    self.upvalVars[scope][id] = true
end

function BC:isUpvalue(scope, id)
    return self.upvalVars[scope] and self.upvalVars[scope][id]
end

-- ── compileFunction ───────────────────────────────────────────────────────────

-- Compiles a function node (or TopNode) into a new Proto.
-- Returns the completed proto.
function BC:compileFunction(node, parentProto, funcDepth, isTop)
    funcDepth = funcDepth or 0
    local args = isTop and {} or (node.args or {})
    local isVararg = false
    local paramCount = 0

    -- Count params, detect vararg
    for i, arg in ipairs(args) do
        if arg.kind == AstKind.VarargExpression then
            isVararg = true
        else
            paramCount = paramCount + 1
        end
    end

    local proto = self:newProto(paramCount, isVararg)
    self.scopeFuncDepths[isTop and ast or node] = funcDepth

    -- Upvalue capture state for this function
    local upvalCaptures = {}   -- {scope, id} -> closure slot index (0-based)
    local upvalSlotCount = 0

    local outerGetUpval  = self.getUpvalSlot
    self.getUpvalSlot = function(self2, scope, id)
        local key = tostring(scope) .. ":" .. tostring(id)
        if upvalCaptures[key] then return upvalCaptures[key] end
        local slot = upvalSlotCount
        upvalSlotCount = upvalSlotCount + 1
        upvalCaptures[key] = slot
        return slot
    end

    -- Register map: (scope, varId) -> register number
    local regMap = {}
    local function getVarReg(scope, id)
        local key = tostring(scope) .. ":" .. tostring(id)
        if regMap[key] then return regMap[key] end
        local r = self:allocReg(proto)
        regMap[key] = r
        return r
    end
    -- Read-only: returns nil for unknowns (used as parentGetVarReg to prevent spurious captures)
    local function getVarRegRO(scope, id)
        return regMap[tostring(scope) .. ":" .. tostring(id)]
    end

    -- Load function arguments into their registers
    for i, arg in ipairs(args) do
        if arg.kind ~= AstKind.VarargExpression then
            local r = getVarReg(arg.scope, arg.id)
            -- Params land in R[0..paramCount-1] by VM convention; just ensure mapping
            regMap[tostring(arg.scope) .. ":" .. tostring(arg.id)] = i - 1
        end
    end
    proto.regNext = paramCount  -- params occupy regs 0..paramCount-1

    -- vararg register: a table holding extra args
    local varargReg = nil
    if isVararg then
        varargReg = self:allocReg(proto)
        -- VARARG 0 = pack all extra args into R[varargReg] as a table
        self:emit(proto, OP.VARARG, varargReg, 0, 0)
    end

    -- Compile the body
    local bodyNode = isTop and node.body or node.body
    self._outerGetVarRegRO = getVarRegRO
    self:compileBlock(proto, bodyNode, funcDepth, getVarReg, varargReg)
    self._outerGetVarRegRO = nil

    -- Implicit return nil at end
    self:emit(proto, OP.RETURN, 0, 1, 0)  -- return nothing

    proto.max_reg    = proto.maxRegSeen + 1
    proto.upvalSlots = upvalSlotCount
    proto.upvalCaptures = upvalCaptures

    self.getUpvalSlot = outerGetUpval

    return proto, upvalCaptures
end

-- ── compileBlock ──────────────────────────────────────────────────────────────

function BC:compileBlock(proto, block, funcDepth, getVarReg, varargReg)
    for _, stat in ipairs(block.statements) do
        self:compileStatement(proto, stat, funcDepth, getVarReg, varargReg)
    end
    -- Clear local variables at block end
    for id, _ in ipairs(block.scope.variables or {}) do
        local key = tostring(block.scope) .. ":" .. tostring(id)
        -- If it was an upvalue, free it
        if self:isUpvalue(block.scope, id) then
            local r = getVarReg(block.scope, id)
            self:emit(proto, OP.FREE_UPVAL, r, 0, 0)
        end
    end
end

-- ── compileStatement ──────────────────────────────────────────────────────────

function BC:compileStatement(proto, stat, funcDepth, getVarReg, varargReg)
    local k = stat.kind

    -- RETURN
    if k == AstKind.ReturnStatement then
        local args = stat.args
        if #args == 0 then
            self:emit(proto, OP.RETURN, 0, 1, 0)
        elseif #args == 1 then
            local last = args[1]
            if last.kind == AstKind.FunctionCallExpression
            or last.kind == AstKind.PassSelfFunctionCallExpression then
                -- multi-return: CALLM then RETURNM
                local r = self:compileExpr(proto, last, funcDepth, getVarReg, varargReg, self.RETURN_ALL)
                self:emit(proto, OP.RETURNM, r, 0, 0)
                self:freeReg(proto, r)
            elseif last.kind == AstKind.VarargExpression then
                self:emit(proto, OP.RETURNM, varargReg, 0, 0)
            else
                local r = self:compileExpr(proto, last, funcDepth, getVarReg, varargReg, 1)
                self:emit(proto, OP.RETURN, r, 2, 0)
                self:freeReg(proto, r)
            end
        else
            -- Multiple return values: build consecutive sequence base..base+n-1
            local savedRegNext = proto.regNext
            local base = proto.regNext
            local retRegs = {}
            for i, expr in ipairs(args) do
                if i == #args and (expr.kind == AstKind.FunctionCallExpression
                    or expr.kind == AstKind.PassSelfFunctionCallExpression
                    or expr.kind == AstKind.VarargExpression) then
                    local r = self:compileExpr(proto, expr, funcDepth, getVarReg, varargReg, self.RETURN_ALL)
                    self:emit(proto, OP.RETURNM, r, 0, 0)
                    proto.regNext = savedRegNext
                    return
                else
                    -- Force allocation into base+i-1 by ensuring regNext is there
                    proto.regNext = base + i - 1
                    local r = self:compileExpr(proto, expr, funcDepth, getVarReg, varargReg, 1)
                    if r ~= base + i - 1 then
                        -- Ensure slot exists
                        if base + i - 1 >= proto.regNext then proto.regNext = base + i end
                        self:emit(proto, OP.MOVE, base + i - 1, r, 0)
                    end
                    retRegs[i] = base + i - 1
                    proto.regNext = base + i  -- advance past this slot
                end
            end
            self:emit(proto, OP.RETURN, base, #args + 1, 0)
            proto.regNext = savedRegNext
        end
        return
    end

    -- LOCAL VARIABLE DECLARATION
    if k == AstKind.LocalVariableDeclaration then
        local ids   = stat.ids
        local exprs = stat.expressions
        -- Ensure all dest regs are allocated in order first
        local dstRegs = {}
        for i, id in ipairs(ids) do
            dstRegs[i] = getVarReg(stat.scope, id)
        end

        local i = 1
        while i <= #ids do
            local expr = exprs[i]
            local dstReg = dstRegs[i]
            if expr then
                local isLastExpr = (i == #exprs or i == #ids)
                local remainingIds = #ids - i + 1  -- how many ids still need values from this point
                local isCallExpr = (expr.kind == AstKind.FunctionCallExpression
                    or expr.kind == AstKind.PassSelfFunctionCallExpression
                    or expr.kind == AstKind.VarargExpression)

                if isLastExpr and remainingIds > 1 and isCallExpr then
                    -- Single call/vararg that needs to fill multiple registers
                    -- Emit CALL with C=remainingIds, results land at callBase..callBase+remainingIds-1
                    -- Force proto.regNext to dstReg so CALL lands results there
                    local savedRegNext = proto.regNext
                    proto.regNext = dstReg
                    local callR = self:compileExpr(proto, expr, funcDepth, getVarReg, varargReg, remainingIds)
                    -- Results are now at callR..callR+remainingIds-1
                    for j = 1, remainingIds do
                        local tgt = dstRegs[i + j - 1]
                        local src = callR + j - 1
                        if src ~= tgt then
                            self:emit(proto, OP.MOVE, tgt, src, 0)
                        end
                    end
                    proto.regNext = savedRegNext
                    i = i + remainingIds  -- skip all filled ids
                else
                    -- Single result expression
                    local r = self:compileExpr(proto, expr, funcDepth, getVarReg, varargReg, 1)
                    if r ~= dstReg then self:emit(proto, OP.MOVE, dstReg, r, 0) end
                    self:freeReg(proto, r)
                    i = i + 1
                end
            else
                self:emit(proto, OP.LOADNIL, dstReg, 0, 0)
                i = i + 1
            end
            -- Upvalue allocation for this id
            local id = ids[i - 1]
            if id and self:isUpvalue(stat.scope, id) then
                self:emit(proto, OP.ALLOC_UPVAL, dstRegs[i-1], 0, 0)
            end
        end
        if not self.scopeFuncDepths[stat.scope] then
            self.scopeFuncDepths[stat.scope] = funcDepth
        end
        return
    end

    -- ASSIGNMENT
    if k == AstKind.AssignmentStatement then
        local lhs = stat.lhs
        local rhs = stat.rhs
        -- Evaluate RHS first
        local rhsRegs = {}
        for i, expr in ipairs(rhs) do
            if i == #rhs and #lhs > #rhs then
                local regs = self:compileExprMulti(proto, expr, funcDepth, getVarReg, varargReg, #lhs - #rhs + 1)
                for _, r in ipairs(regs) do rhsRegs[#rhsRegs+1] = r end
            else
                rhsRegs[#rhsRegs+1] = self:compileExpr(proto, expr, funcDepth, getVarReg, varargReg, 1)
            end
        end
        -- Assign
        for i, target in ipairs(lhs) do
            local valReg = rhsRegs[i] or (function()
                local r = self:allocReg(proto)
                self:emit(proto, OP.LOADNIL, r, 0, 0)
                return r
            end)()
            if target.kind == AstKind.AssignmentVariable then
                if target.scope.isGlobal then
                    local kIdx = self:addConst(proto, target.scope:getVariableName(target.id))
                    self:emit(proto, OP.SETGLOBAL, valReg, kIdx, 0)
                else
                    local handled = false
                    -- Cross-function capture check
                    if self._captureFn then
                        local capSlot = self._captureFn(target.scope, target.id)
                        if not capSlot then
                            getVarReg(target.scope, target.id)
                            capSlot = self._captureFn(target.scope, target.id)
                        end
                        if capSlot then
                            -- Cross-function: load capSlot literal into temp reg
                            local slotLitReg = self:allocReg(proto)
                            self:emit(proto, OP.LOADINT, slotLitReg, 0, capSlot)
                            self:emit(proto, OP.SET_UPVAL, slotLitReg, valReg, 0)
                            self:freeReg(proto, slotLitReg)
                            self:freeReg(proto, valReg)
                            handled = true
                        end
                    end
                    if not handled then
                        local dstReg = getVarReg(target.scope, target.id)
                        if self:isUpvalue(target.scope, target.id) then
                            -- dstReg holds the slot id; SET_UPVAL A=dstReg B=valReg
                            self:emit(proto, OP.SET_UPVAL, dstReg, valReg, 0)
                        else
                            if valReg ~= dstReg then
                                self:emit(proto, OP.MOVE, dstReg, valReg, 0)
                            end
                        end
                    end
                end
            elseif target.kind == AstKind.AssignmentIndexing then
                local baseR  = self:compileExpr(proto, target.base,  funcDepth, getVarReg, varargReg, 1)
                local idxR   = self:compileExpr(proto, target.index, funcDepth, getVarReg, varargReg, 1)
                self:emit(proto, OP.SETTABLE, baseR, idxR, valReg)
                self:freeReg(proto, idxR)
                self:freeReg(proto, baseR)
            end
            self:freeReg(proto, valReg)
        end
        return
    end

    -- FUNCTION CALL STATEMENT
    if k == AstKind.FunctionCallStatement then
        self:emitCall(proto, stat.base, stat.args, funcDepth, getVarReg, varargReg, false, -1)
        return
    end

    -- PASS SELF FUNCTION CALL STATEMENT  (obj:method(args))
    if k == AstKind.PassSelfFunctionCallStatement then
        self:emitPassSelfCall(proto, stat.base, stat.passSelfFunctionName, stat.args, funcDepth, getVarReg, varargReg, false, -1)
        return
    end

    -- LOCAL FUNCTION DECLARATION
    if k == AstKind.LocalFunctionDeclaration then
        local dstReg = getVarReg(stat.scope, stat.id)
        local isUpval = self:isUpvalue(stat.scope, stat.id)
        if isUpval then
            self:emit(proto, OP.ALLOC_UPVAL, dstReg, 0, 0)
            -- dstReg now holds the slot id; DON'T overwrite it with the closure
        end
        -- compileFunctionNode emits CLOSURE into proto and returns the closure reg
        local closureR, _ = self:compileFunctionNode(proto, stat, funcDepth, getVarReg)
        if isUpval then
            -- Write closure into the upval box (dstReg holds slot id)
            self:emit(proto, OP.SET_UPVAL, dstReg, closureR, 0)
        else
            if closureR ~= dstReg then
                self:emit(proto, OP.MOVE, dstReg, closureR, 0)
            end
        end
        if not self.scopeFuncDepths[stat.scope] then
            self.scopeFuncDepths[stat.scope] = funcDepth
        end
        return
    end

    -- FUNCTION DECLARATION (global or indexed)
    if k == AstKind.FunctionDeclaration then
        -- compileFunctionNode now emits CLOSURE into proto and returns dstR
        local closureR, _ = self:compileFunctionNode(proto, stat, funcDepth, getVarReg)
        if stat.scope.isGlobal then
            local kIdx = self:addConst(proto, stat.scope:getVariableName(stat.id))
            if #stat.indices == 0 then
                self:emit(proto, OP.SETGLOBAL, closureR, kIdx, 0)
            else
                local tblR = self:allocReg(proto)
                self:emit(proto, OP.GETGLOBAL, tblR, kIdx, 0)
                for j = 1, #stat.indices - 1 do
                    local kR = self:allocReg(proto)
                    local ik = self:addConst(proto, stat.indices[j])
                    self:emit(proto, OP.LOADSTR, kR, ik, 0)
                    local nxtR = self:allocReg(proto)
                    self:emit(proto, OP.GETTABLE, nxtR, tblR, kR)
                    self:freeReg(proto, kR); self:freeReg(proto, tblR)
                    tblR = nxtR
                end
                local kR = self:allocReg(proto)
                local ik = self:addConst(proto, stat.indices[#stat.indices])
                self:emit(proto, OP.LOADSTR, kR, ik, 0)
                self:emit(proto, OP.SETTABLE, tblR, kR, closureR)
                self:freeReg(proto, kR); self:freeReg(proto, tblR)
            end
        else
            local varR = getVarReg(stat.scope, stat.id)
            if self:isUpvalue(stat.scope, stat.id) then
                self:emit(proto, OP.SET_UPVAL, varR, closureR, 0)
            else
                if closureR ~= varR then
                    self:emit(proto, OP.MOVE, varR, closureR, 0)
                end
            end
        end
        self:freeReg(proto, closureR)
        return
    end

    -- IF STATEMENT
    if k == AstKind.IfStatement then
        local condR = self:compileExpr(proto, stat.condition, funcDepth, getVarReg, varargReg, 1)
        local jmpF  = self:emitJmp(proto, OP.JMPF, condR)
        self:freeReg(proto, condR)

        self:compileBlock(proto, stat.body, funcDepth, getVarReg, varargReg)

        local endJmps = {}
        if stat.elsebody or #stat.elseifs > 0 then
            endJmps[1] = self:emitJmp(proto, OP.JMP, 0)
        end

        self:patchJmp(proto, jmpF, #proto.instrs + 1)

        for i, eif in ipairs(stat.elseifs) do
            local eifCondR = self:compileExpr(proto, eif.condition, funcDepth, getVarReg, varargReg, 1)
            local eifJmpF  = self:emitJmp(proto, OP.JMPF, eifCondR)
            self:freeReg(proto, eifCondR)
            self:compileBlock(proto, eif.body, funcDepth, getVarReg, varargReg)
            if stat.elsebody or i < #stat.elseifs then
                endJmps[#endJmps+1] = self:emitJmp(proto, OP.JMP, 0)
            end
            self:patchJmp(proto, eifJmpF, #proto.instrs + 1)
        end

        if stat.elsebody then
            self:compileBlock(proto, stat.elsebody, funcDepth, getVarReg, varargReg)
        end

        local endTarget = #proto.instrs + 1
        for _, j in ipairs(endJmps) do self:patchJmp(proto, j, endTarget) end
        return
    end

    -- WHILE STATEMENT
    if k == AstKind.WhileStatement then
        local loopTop = #proto.instrs + 1
        local condR   = self:compileExpr(proto, stat.condition, funcDepth, getVarReg, varargReg, 1)
        local jmpF    = self:emitJmp(proto, OP.JMPF, condR)
        self:freeReg(proto, condR)
        stat.__bc_break_patches  = {}
        stat.__bc_cont_patches   = {}
        stat.__bc_loop_top       = loopTop
        self:compileBlock(proto, stat.body, funcDepth, getVarReg, varargReg)
        self:emit(proto, OP.JMP, 0, loopTop, 0)
        local afterLoop = #proto.instrs + 1
        self:patchJmp(proto, jmpF, afterLoop)
        for _, j in ipairs(stat.__bc_break_patches) do self:patchJmp(proto, j, afterLoop) end
        for _, j in ipairs(stat.__bc_cont_patches)  do self:patchJmp(proto, j, loopTop) end
        return
    end

    -- REPEAT STATEMENT
    if k == AstKind.RepeatStatement then
        local loopTop = #proto.instrs + 1
        stat.__bc_break_patches = {}
        stat.__bc_cont_patches  = {}
        stat.__bc_loop_top      = loopTop
        for _, s in ipairs(stat.body.statements) do
            self:compileStatement(proto, s, funcDepth, getVarReg, varargReg)
        end
        local condR = self:compileExpr(proto, stat.condition, funcDepth, getVarReg, varargReg, 1)
        local jmpF  = self:emitJmp(proto, OP.JMPF, condR)
        self:freeReg(proto, condR)
        local afterLoop = #proto.instrs + 1
        self:patchJmp(proto, jmpF, afterLoop)
        -- repeat loops backwards: condition false means continue looping
        -- re-patch: jmpF should jump to TOP (keep looping), fall through = done
        proto.instrs[jmpF][3] = loopTop
        self:emit(proto, OP.JMP, 0, afterLoop, 0)  -- when condition true, skip to after
        -- fix: need invert — emit JMPT instead
        proto.instrs[jmpF][1] = OP.JMPT
        proto.instrs[jmpF][3] = afterLoop
        self:emit(proto, OP.JMP, 0, loopTop, 0)
        local realAfter = #proto.instrs + 1
        self:patchJmp(proto, #proto.instrs, realAfter)
        for _, j in ipairs(stat.__bc_break_patches) do self:patchJmp(proto, j, realAfter) end
        for _, j in ipairs(stat.__bc_cont_patches)  do self:patchJmp(proto, j, loopTop) end
        return
    end

    -- FOR STATEMENT  (numeric for)
    if k == AstKind.ForStatement then
        local initR  = self:compileExpr(proto, stat.initialValue, funcDepth, getVarReg, varargReg, 1)
        local limitR = self:compileExpr(proto, stat.finalValue,   funcDepth, getVarReg, varargReg, 1)
        local stepR  = self:compileExpr(proto, stat.incrementBy,  funcDepth, getVarReg, varargReg, 1)

        -- cntR = init - step  (first iteration: cnt+step = init)
        local cntR = self:allocReg(proto)
        self:emit(proto, OP.SUB, cntR, initR, stepR)
        -- initR no longer needed
        -- NOTE: do NOT freeReg initR/limitR/stepR/cntR here — keep them live
        -- for the entire loop so the body can't reuse those slots.

        -- posStepR = (step >= 1)
        local oneR = self:allocReg(proto)
        self:emit(proto, OP.LOADINT, oneR, 0, 1)
        local posStepR = self:allocReg(proto)
        self:emit(proto, OP.GE, posStepR, stepR, oneR)
        -- oneR done but keep it pinned so allocReg doesn't give it to loop body
        -- (we'll free everything together after the loop)

        -- Preallocate condR, fwdR, bwdR so the loop body can't steal them
        local fwdR  = self:allocReg(proto)
        local bwdR  = self:allocReg(proto)
        local condR = self:allocReg(proto)

        stat.__bc_break_patches = {}
        stat.__bc_cont_patches  = {}

        -- Loop top: cnt = cnt + step
        local loopTop = #proto.instrs + 1
        self:emit(proto, OP.ADD, cntR, cntR, stepR)

        -- Condition: pick fwd (cnt<=limit) or bwd (cnt>=limit) based on posStepR
        self:emit(proto, OP.LE, fwdR, cntR, limitR)
        self:emit(proto, OP.GE, bwdR, cntR, limitR)

        local jmpToFwd = self:emitJmp(proto, OP.JMPT, posStepR)
        self:emit(proto, OP.MOVE, condR, bwdR, 0)
        local jmpOverFwd = self:emitJmp(proto, OP.JMP, 0)
        self:patchJmp(proto, jmpToFwd, #proto.instrs + 1)
        self:emit(proto, OP.MOVE, condR, fwdR, 0)
        self:patchJmp(proto, jmpOverFwd, #proto.instrs + 1)

        local jmpExit = self:emitJmp(proto, OP.JMPF, condR)

        -- Assign loop variable
        local varR = getVarReg(stat.scope, stat.id)
        self:emit(proto, OP.MOVE, varR, cntR, 0)
        if self:isUpvalue(stat.scope, stat.id) then
            self:emit(proto, OP.ALLOC_UPVAL, varR, 0, 0)
            self:emit(proto, OP.SET_UPVAL, varR, cntR, 0)
        end
        if not self.scopeFuncDepths[stat.scope] then
            self.scopeFuncDepths[stat.scope] = funcDepth
        end

        stat.__bc_loop_top = loopTop
        self:compileBlock(proto, stat.body, funcDepth, getVarReg, varargReg)
        self:emit(proto, OP.JMP, 0, loopTop, 0)

        local afterLoop = #proto.instrs + 1
        self:patchJmp(proto, jmpExit, afterLoop)

        -- Free all loop control registers now that the loop is done
        self:freeReg(proto, condR)
        self:freeReg(proto, bwdR)
        self:freeReg(proto, fwdR)
        self:freeReg(proto, posStepR)
        self:freeReg(proto, oneR)
        self:freeReg(proto, cntR)
        self:freeReg(proto, limitR)
        self:freeReg(proto, stepR)
        self:freeReg(proto, initR)

        for _, j in ipairs(stat.__bc_break_patches) do self:patchJmp(proto, j, afterLoop) end
        for _, j in ipairs(stat.__bc_cont_patches)  do self:patchJmp(proto, j, loopTop) end
        return
    end

    -- FOR IN STATEMENT
    if k == AstKind.ForInStatement then
        local exprs = stat.expressions
        -- Need: iterFunc(R0), state(R1), control(R2)
        local iterR  = self:allocReg(proto)
        local stateR = self:allocReg(proto)
        local ctrlR  = self:allocReg(proto)

        local function loadExpr(i, target)
            if exprs[i] then
                local r = self:compileExpr(proto, exprs[i], funcDepth, getVarReg, varargReg, 1)
                if r ~= target then self:emit(proto, OP.MOVE, target, r, 0) end
                self:freeReg(proto, r)
            else
                self:emit(proto, OP.LOADNIL, target, 0, 0)
            end
        end
        loadExpr(1, iterR); loadExpr(2, stateR); loadExpr(3, ctrlR)

        local loopTop = #proto.instrs + 1
        -- Call: results = iterFunc(state, ctrl)
        local resBase = self:allocReg(proto)
        -- CALLM: multi-return call, pack results into resBase
        -- We model it as: resBase = {iterR(stateR, ctrlR)}
        local tmpIter  = self:allocReg(proto)
        local tmpState = self:allocReg(proto)
        local tmpCtrl  = self:allocReg(proto)
        self:emit(proto, OP.MOVE, tmpIter,  iterR,  0)
        self:emit(proto, OP.MOVE, tmpState, stateR, 0)
        self:emit(proto, OP.MOVE, tmpCtrl,  ctrlR,  0)
        self:emit(proto, OP.CALLM, tmpIter, 3, resBase)  -- CALLM: fn=tmpIter, nargs=2 (state,ctrl), dst=resBase
        self:freeReg(proto, tmpCtrl); self:freeReg(proto, tmpState); self:freeReg(proto, tmpIter)

        -- ctrl = results[1]
        local oneK = self:addConst(proto, 1)
        local oneR = self:allocReg(proto)
        self:emit(proto, OP.LOADINT, oneR, 0, oneK)
        self:emit(proto, OP.GETTABLE, ctrlR, resBase, oneR)
        self:freeReg(proto, oneR)

        -- if ctrl == nil then break
        local nilR  = self:allocReg(proto)
        self:emit(proto, OP.LOADNIL, nilR, 0, 0)
        local eqR = self:allocReg(proto)
        self:emit(proto, OP.EQ, eqR, ctrlR, nilR)
        self:freeReg(proto, nilR)
        local jmpBreak = self:emitJmp(proto, OP.JMPT, eqR)
        self:freeReg(proto, eqR)

        -- Assign loop variables from results
        for i, id in ipairs(stat.ids) do
            local varR = getVarReg(stat.scope, id)
            local kIdx = self:addConst(proto, i)
            local kR   = self:allocReg(proto)
            self:emit(proto, OP.LOADINT, kR, 0, kIdx)
            self:emit(proto, OP.GETTABLE, varR, resBase, kR)
            self:freeReg(proto, kR)
            if self:isUpvalue(stat.scope, id) then
                self:emit(proto, OP.ALLOC_UPVAL, varR, 0, 0)
                self:emit(proto, OP.SET_UPVAL, varR, varR, 0)
            end
        end

        stat.__bc_break_patches = {}
        stat.__bc_cont_patches  = {}
        stat.__bc_loop_top      = loopTop
        self:compileBlock(proto, stat.body, funcDepth, getVarReg, varargReg)
        self:emit(proto, OP.JMP, 0, loopTop, 0)

        local afterLoop = #proto.instrs + 1
        self:patchJmp(proto, jmpBreak, afterLoop)
        self:freeReg(proto, resBase)
        self:freeReg(proto, ctrlR); self:freeReg(proto, stateR); self:freeReg(proto, iterR)
        for _, j in ipairs(stat.__bc_break_patches) do self:patchJmp(proto, j, afterLoop) end
        for _, j in ipairs(stat.__bc_cont_patches)  do self:patchJmp(proto, j, loopTop) end
        return
    end

    -- BREAK
    if k == AstKind.BreakStatement then
        local j = self:emitJmp(proto, OP.JMP, 0)
        local loop = stat.loop
        if loop and loop.__bc_break_patches then
            loop.__bc_break_patches[#loop.__bc_break_patches+1] = j
        end
        return
    end

    -- CONTINUE
    if k == AstKind.ContinueStatement then
        local j = self:emitJmp(proto, OP.JMP, 0)
        local loop = stat.loop
        if loop and loop.__bc_cont_patches then
            loop.__bc_cont_patches[#loop.__bc_cont_patches+1] = j
        end
        return
    end

    -- DO STATEMENT
    if k == AstKind.DoStatement then
        self:compileBlock(proto, stat.body, funcDepth, getVarReg, varargReg)
        return
    end

    -- Compound statements (+=, -=, etc.)
    local compoundOps = {
        [AstKind.CompoundAddStatement]    = OP.ADD,
        [AstKind.CompoundSubStatement]    = OP.SUB,
        [AstKind.CompoundMulStatement]    = OP.MUL,
        [AstKind.CompoundDivStatement]    = OP.DIV,
        [AstKind.CompoundModStatement]    = OP.MOD,
        [AstKind.CompoundPowStatement]    = OP.POW,
        [AstKind.CompoundConcatStatement] = OP.CONCAT,
    }
    if compoundOps[k] then
        local rhsR = self:compileExpr(proto, stat.rhs, funcDepth, getVarReg, varargReg, 1)
        local lhsTarget = stat.lhs
        if lhsTarget.kind == AstKind.AssignmentVariable then
            local varR = getVarReg(lhsTarget.scope, lhsTarget.id)
            local tmpR = self:allocReg(proto)
            if self:isUpvalue(lhsTarget.scope, lhsTarget.id) then
                self:emit(proto, OP.GET_UPVAL, tmpR, varR, 0)
                self:emit(proto, compoundOps[k], tmpR, tmpR, rhsR)
                self:emit(proto, OP.SET_UPVAL, varR, tmpR, 0)
            else
                self:emit(proto, compoundOps[k], varR, varR, rhsR)
            end
            self:freeReg(proto, tmpR)
        elseif lhsTarget.kind == AstKind.AssignmentIndexing then
            local baseR = self:compileExpr(proto, lhsTarget.base,  funcDepth, getVarReg, varargReg, 1)
            local idxR  = self:compileExpr(proto, lhsTarget.index, funcDepth, getVarReg, varargReg, 1)
            local curR  = self:allocReg(proto)
            self:emit(proto, OP.GETTABLE, curR, baseR, idxR)
            self:emit(proto, compoundOps[k], curR, curR, rhsR)
            self:emit(proto, OP.SETTABLE, baseR, idxR, curR)
            self:freeReg(proto, curR); self:freeReg(proto, idxR); self:freeReg(proto, baseR)
        end
        self:freeReg(proto, rhsR)
        return
    end

    logger:error("BytecodeCompiler: unhandled statement kind: " .. tostring(k))
end

-- ── compileExpr ───────────────────────────────────────────────────────────────

-- Returns a register holding the result (1 value).
-- numReturns: 1 = single, RETURN_ALL = multi-return (result is packed table).
function BC:compileExpr(proto, expr, funcDepth, getVarReg, varargReg, numReturns)
    numReturns = numReturns or 1
    local k = expr.kind

    if k == AstKind.NilExpression then
        local r = self:allocReg(proto)
        self:emit(proto, OP.LOADNIL, r, 0, 0)
        return r
    end

    if k == AstKind.BooleanExpression then
        local r = self:allocReg(proto)
        self:emit(proto, OP.LOADBOOL, r, expr.value and 1 or 0, 0)
        return r
    end

    if k == AstKind.NumberExpression then
        local v = expr.value
        local r = self:allocReg(proto)
        if v == math.floor(v) and v >= -32768 and v <= 32767 then
            -- small integer: encode directly in B/C fields
            local enc = v < 0 and (v + 65536) or v
            self:emit(proto, OP.LOADINT, r, math.floor(enc / 256), enc % 256)
        else
            local kIdx = self:addConst(proto, v)
            self:emit(proto, OP.LOADFLOAT, r, kIdx, 0)
        end
        return r
    end

    if k == AstKind.StringExpression then
        local kIdx = self:addConst(proto, expr.value)
        local r    = self:allocReg(proto)
        self:emit(proto, OP.LOADSTR, r, kIdx, 0)
        return r
    end

    if k == AstKind.VariableExpression then
        if expr.scope.isGlobal then
            local kIdx = self:addConst(proto, expr.scope:getVariableName(expr.id))
            local r    = self:allocReg(proto)
            self:emit(proto, OP.GETGLOBAL, r, kIdx, 0)
            return r
        else
            -- Cross-function capture check
            if self._captureFn then
                local capSlot = self._captureFn(expr.scope, expr.id)
                if not capSlot then
                    local raw = getVarReg(expr.scope, expr.id)
                    capSlot = self._captureFn(expr.scope, expr.id)
                    if not capSlot then
                        -- Regular local variable
                        if self:isUpvalue(expr.scope, expr.id) then
                            -- Same-function upval: raw holds slot id in Stk
                            local r = self:allocReg(proto)
                            self:emit(proto, OP.GET_UPVAL, r, raw, 0)
                            return r
                        end
                        return raw
                    end
                end
                -- Cross-function: capSlot is a literal slot number
                -- Load it into a temp reg, then GET_UPVAL uses that reg
                local slotLitReg = self:allocReg(proto)
                self:emit(proto, OP.LOADINT, slotLitReg, 0, capSlot)
                local r = self:allocReg(proto)
                self:emit(proto, OP.GET_UPVAL, r, slotLitReg, 0)
                self:freeReg(proto, slotLitReg)
                return r
            end
            -- Same-function variable (no _captureFn active)
            local varR = getVarReg(expr.scope, expr.id)
            if self:isUpvalue(expr.scope, expr.id) then
                local r = self:allocReg(proto)
                self:emit(proto, OP.GET_UPVAL, r, varR, 0)
                return r
            end
            return varR
        end
    end

    if k == AstKind.VarargExpression then
        if numReturns == self.RETURN_ALL then
            return varargReg or (function()
                local r = self:allocReg(proto)
                self:emit(proto, OP.VARARG, r, 0, 0)
                return r
            end)()
        else
            local r = self:allocReg(proto)
            local kIdx = self:addConst(proto, numReturns)
            self:emit(proto, OP.VARARG, r, numReturns, 0)
            return r
        end
    end

    if k == AstKind.IndexExpression then
        local baseR = self:compileExpr(proto, expr.base,  funcDepth, getVarReg, varargReg, 1)
        local idxR  = self:compileExpr(proto, expr.index, funcDepth, getVarReg, varargReg, 1)
        local r     = self:allocReg(proto)
        self:emit(proto, OP.GETTABLE, r, baseR, idxR)
        self:freeReg(proto, idxR)
        self:freeReg(proto, baseR)
        return r
    end

    -- Binary ops
    if BIN_OP_MAP[k] then
        local lR = self:compileExpr(proto, expr.lhs, funcDepth, getVarReg, varargReg, 1)
        local rR = self:compileExpr(proto, expr.rhs, funcDepth, getVarReg, varargReg, 1)
        local r  = self:allocReg(proto)
        self:emit(proto, BIN_OP_MAP[k], r, lR, rR)
        self:freeReg(proto, rR); self:freeReg(proto, lR)
        return r
    end

    if k == AstKind.NotExpression then
        local rR = self:compileExpr(proto, expr.rhs, funcDepth, getVarReg, varargReg, 1)
        local r  = self:allocReg(proto)
        self:emit(proto, OP.NOT, r, rR, 0)
        self:freeReg(proto, rR)
        return r
    end

    if k == AstKind.NegateExpression then
        local rR = self:compileExpr(proto, expr.rhs, funcDepth, getVarReg, varargReg, 1)
        local r  = self:allocReg(proto)
        self:emit(proto, OP.UNM, r, rR, 0)
        self:freeReg(proto, rR)
        return r
    end

    if k == AstKind.LenExpression then
        local rR = self:compileExpr(proto, expr.rhs, funcDepth, getVarReg, varargReg, 1)
        local r  = self:allocReg(proto)
        self:emit(proto, OP.LEN, r, rR, 0)
        self:freeReg(proto, rR)
        return r
    end

    if k == AstKind.OrExpression then
        local lR  = self:compileExpr(proto, expr.lhs, funcDepth, getVarReg, varargReg, 1)
        local r   = self:allocReg(proto)
        self:emit(proto, OP.MOVE, r, lR, 0)
        local jmpT = self:emitJmp(proto, OP.JMPT, lR)  -- if lhs truthy, skip rhs
        self:freeReg(proto, lR)
        local rR   = self:compileExpr(proto, expr.rhs, funcDepth, getVarReg, varargReg, 1)
        self:emit(proto, OP.MOVE, r, rR, 0)
        self:freeReg(proto, rR)
        self:patchJmp(proto, jmpT, #proto.instrs + 1)
        return r
    end

    if k == AstKind.AndExpression then
        local lR  = self:compileExpr(proto, expr.lhs, funcDepth, getVarReg, varargReg, 1)
        local r   = self:allocReg(proto)
        self:emit(proto, OP.MOVE, r, lR, 0)
        local jmpF = self:emitJmp(proto, OP.JMPF, lR)  -- if lhs falsy, skip rhs
        self:freeReg(proto, lR)
        local rR   = self:compileExpr(proto, expr.rhs, funcDepth, getVarReg, varargReg, 1)
        self:emit(proto, OP.MOVE, r, rR, 0)
        self:freeReg(proto, rR)
        self:patchJmp(proto, jmpF, #proto.instrs + 1)
        return r
    end

    if k == AstKind.TableConstructorExpression then
        local r = self:allocReg(proto)
        self:emit(proto, OP.NEWTABLE, r, 0, 0)
        local arrayIdx = 1
        for i, entry in ipairs(expr.entries) do
            if entry.kind == AstKind.TableEntry then
                local isLast = (i == #expr.entries)
                local val = entry.value
                if isLast and (val.kind == AstKind.FunctionCallExpression
                    or val.kind == AstKind.PassSelfFunctionCallExpression
                    or val.kind == AstKind.VarargExpression) then
                    -- multi-return into array slots
                    local vR = self:compileExpr(proto, val, funcDepth, getVarReg, varargReg, self.RETURN_ALL)
                    -- CALLM result is a packed table; unpack into array
                    -- emit a loop or specialized opcode — use a helper emit
                    local startK = self:addConst(proto, arrayIdx)
                    local startR = self:allocReg(proto)
                    self:emit(proto, OP.LOADINT, startR, 0, startK)
                    -- SETTABLE r[startR..] = unpack(vR) — use SETRETM semantics via special opcode
                    -- We use VARARG-like expansion: custom approach — pack into table via inline loop
                    -- Simplest correct approach: just setret each element
                    -- For now: store the packed table directly as array part
                    local lenR = self:allocReg(proto)
                    self:emit(proto, OP.LEN, lenR, vR, 0)
                    -- Inline for i=1,len do r[startIdx+i-1]=vR[i] end
                    -- This gets complex; use a simpler encoding: CALLM stores to consecutive regs
                    -- We'll just use GETTABLE in a loop by emitting CALLM with dst=r, start=arrayIdx
                    self:emit(proto, OP.CALLM, vR, 0xFFFF, r)  -- special: unpack vR into r starting at arrayIdx
                    self:freeReg(proto, lenR); self:freeReg(proto, startR)
                    self:freeReg(proto, vR)
                else
                    local vR = self:compileExpr(proto, val, funcDepth, getVarReg, varargReg, 1)
                    local kIdx = self:addConst(proto, arrayIdx)
                    local kR   = self:allocReg(proto)
                    self:emit(proto, OP.LOADINT, kR, 0, kIdx)
                    self:emit(proto, OP.SETTABLE, r, kR, vR)
                    self:freeReg(proto, kR); self:freeReg(proto, vR)
                    arrayIdx = arrayIdx + 1
                end
            else
                -- keyed entry
                local kR = self:compileExpr(proto, entry.key,   funcDepth, getVarReg, varargReg, 1)
                local vR = self:compileExpr(proto, entry.value, funcDepth, getVarReg, varargReg, 1)
                self:emit(proto, OP.SETTABLE, r, kR, vR)
                self:freeReg(proto, vR); self:freeReg(proto, kR)
            end
        end
        return r
    end

    if k == AstKind.FunctionLiteralExpression then
        return self:compileFunctionExpr(proto, expr, funcDepth, getVarReg, varargReg)
    end

    if k == AstKind.FunctionCallExpression then
        return self:emitCall(proto, expr.base, expr.args, funcDepth, getVarReg, varargReg, true, numReturns)
    end

    if k == AstKind.PassSelfFunctionCallExpression then
        return self:emitPassSelfCall(proto, expr.base, expr.passSelfFunctionName, expr.args, funcDepth, getVarReg, varargReg, true, numReturns)
    end

    logger:error("BytecodeCompiler: unhandled expression kind: " .. tostring(k))
end

function BC:compileExprMulti(proto, expr, funcDepth, getVarReg, varargReg, n)
    local regs = {}
    for i = 1, n do
        regs[i] = self:compileExpr(proto, expr, funcDepth, getVarReg, varargReg, i == 1 and 1 or 1)
        if i > 1 then self:emit(proto, OP.LOADNIL, regs[i], 0, 0) end
    end
    return regs
end

-- ── emitCall helpers ──────────────────────────────────────────────────────────

function BC:emitCall(proto, baseExpr, args, funcDepth, getVarReg, varargReg, wantResult, numReturns)
    -- Reserve the function slot first, then compile args into consecutive slots above it.
    -- This prevents arg compilation from clobbering the function register.
    local callBase = proto.regNext  -- fn lives here
    proto.regNext  = callBase + 1   -- advance so args land above fn

    -- Compile the function expression into callBase
    local fnR = self:compileExpr(proto, baseExpr, funcDepth, getVarReg, varargReg, 1)
    if fnR ~= callBase then
        self:emit(proto, OP.MOVE, callBase, fnR, 0)
        self:freeReg(proto, fnR)
    end

    -- Compile args into callBase+1, callBase+2, ...
    local nArgs = 0
    local isVarargLast = false
    for i, arg in ipairs(args) do
        local isLast = (i == #args)
        local argSlot = callBase + 1 + nArgs
        if isLast and (arg.kind == AstKind.FunctionCallExpression
            or arg.kind == AstKind.PassSelfFunctionCallExpression
            or arg.kind == AstKind.VarargExpression) then
            -- vararg last arg — compile as RETURN_ALL, result is packed table
            -- but for CALL we need to expand it; use CALLM instead
            local r = self:compileExpr(proto, arg, funcDepth, getVarReg, varargReg, self.RETURN_ALL)
            if r ~= argSlot then
                self:emit(proto, OP.MOVE, argSlot, r, 0)
                self:freeReg(proto, r)
            end
            nArgs = nArgs + 1
            isVarargLast = true
        else
            local r = self:compileExpr(proto, arg, funcDepth, getVarReg, varargReg, 1)
            if r ~= argSlot then
                self:emit(proto, OP.MOVE, argSlot, r, 0)
                self:freeReg(proto, r)
            end
            nArgs = nArgs + 1
        end
    end

    -- Reset regNext past all args
    proto.regNext = callBase + 1 + nArgs

    if not wantResult then
        self:emit(proto, OP.VCALL, callBase, nArgs, 0)
        proto.regNext = callBase
        return nil
    end

    local dstR = callBase  -- result lands in-place

    if numReturns == self.RETURN_ALL then
        -- CALLM: pack all results into a table at dstR
        local tblR = self:allocReg(proto)
        self:emit(proto, OP.CALLM, callBase, nArgs, tblR)
        proto.regNext = callBase
        return tblR
    else
        -- CALL: fixed number of results at callBase..callBase+numReturns-1
        self:emit(proto, OP.CALL, callBase, nArgs, numReturns)
        proto.regNext = callBase + (numReturns > 0 and numReturns or 1)
        return callBase
    end
end

function BC:emitPassSelfCall(proto, baseExpr, methodName, args, funcDepth, getVarReg, varargReg, wantResult, numReturns)
    local selfR   = self:compileExpr(proto, baseExpr, funcDepth, getVarReg, varargReg, 1)
    local kIdx    = self:addConst(proto, methodName)
    local methodR = self:allocReg(proto)
    self:emit(proto, OP.LOADSTR, methodR, kIdx, 0)
    local fnR = self:allocReg(proto)
    self:emit(proto, OP.GETTABLE, fnR, selfR, methodR)
    self:freeReg(proto, methodR)

    -- Build args: [self, ...args]
    local allArgs = {}
    -- inject self as first arg by synthesising a VariableExpression node? No —
    -- we handle it at the CALL emit level: pass selfR directly
    local argBase = proto.regNext
    local selfSlot = argBase
    self:emit(proto, OP.MOVE, selfSlot, selfR, 0)
    proto.regNext = argBase + 1
    local nArgs = 1

    for i, arg in ipairs(args) do
        local isLast = (i == #args)
        if isLast and (arg.kind == AstKind.FunctionCallExpression
            or arg.kind == AstKind.PassSelfFunctionCallExpression
            or arg.kind == AstKind.VarargExpression) then
            local r = self:compileExpr(proto, arg, funcDepth, getVarReg, varargReg, self.RETURN_ALL)
            local slot = argBase + nArgs
            if r ~= slot then self:emit(proto, OP.MOVE, slot, r, 0) end
            self:freeReg(proto, r)
            nArgs = nArgs + 1
        else
            local r    = self:compileExpr(proto, arg, funcDepth, getVarReg, varargReg, 1)
            local slot = argBase + nArgs
            if r ~= slot then self:emit(proto, OP.MOVE, slot, r, 0) end
            self:freeReg(proto, r)
            nArgs = nArgs + 1
        end
    end

    local callBase = argBase - 1
    if fnR ~= callBase then self:emit(proto, OP.MOVE, callBase, fnR, 0) end
    self:freeReg(proto, fnR); self:freeReg(proto, selfR)

    local dstR = self:allocReg(proto)
    if not wantResult then
        self:emit(proto, OP.VCALL, callBase, nArgs, 0)
        self:freeReg(proto, dstR)
        return nil
    end
    if numReturns == self.RETURN_ALL then
        self:emit(proto, OP.CALLM, callBase, nArgs, dstR)
    else
        self:emit(proto, OP.CALL, callBase, nArgs, numReturns)
        if dstR ~= callBase then self:emit(proto, OP.MOVE, dstR, callBase, 0) end
    end
    return dstR
end

-- Compile a function node into a sub-proto and emit CLOSURE into parentProto.
-- Returns the register in parentProto that holds the new closure.
--
-- Captures are stored in a dedicated per-frame `capSlots` table (NOT in Stk)
-- to avoid register number collisions with local variables.
-- GET_UPVAL B=slot reads capSlots[B] directly.
-- SET_UPVAL A=slot B=srcReg writes capSlots[A].v = Stk[B+1].
function BC:compileFunctionNode(parentProto, node, funcDepth, parentGetVarReg)
    local args       = node.args or {}
    local isVararg   = false
    local paramCount = 0
    for _, arg in ipairs(args) do
        if arg.kind == AstKind.VarargExpression then isVararg = true
        else paramCount = paramCount + 1 end
    end

    -- safeParentGet: read-only lookup. Consumes _outerGetVarRegRO so deeper nested
    -- compileFunctionNode calls use their own parentGetVarReg (already safe subGetVarReg).
    local roFn = self._outerGetVarRegRO or parentGetVarReg
    self._outerGetVarRegRO = nil  -- consumed; deeper nesting must not reuse this
    local function safeParentGet(scope, id)
        if not roFn then return nil end
        return roFn(scope, id)
    end

    local subProto  = self:newProto(paramCount, isVararg)
    local subRegMap = {}
    local captureList = {}   -- [slot(1-based)] = parentReg
    local captureKeys = {}   -- ["scope:id"] = slot(1-based)

    local function subGetVarReg(scope, id)
        local key = tostring(scope)..":"..tostring(id)
        if subRegMap[key] then return subRegMap[key] end
        -- Not local — see if parent has it (cross-function capture)
        -- Use safeParentGet so we only capture variables the parent already knew about
        local parentReg = safeParentGet(scope, id)
        if parentReg ~= nil then
            -- Record as capture; slot number used directly in GET/SET_UPVAL B/A fields
            local slot = #captureList + 1
            captureList[slot] = parentReg
            captureKeys[key]  = slot
            subRegMap[key]          = slot  -- slot number, not a register
            subRegMap[key.."__cap"] = slot
            return slot
        end
        -- Fully new local variable
        local r = self:allocReg(subProto)
        subRegMap[key] = r
        return r
    end

    -- isCapture: returns slot (1-based) if this key is a captured upvalue
    local function isCapture(scope, id)
        local key = tostring(scope)..":"..tostring(id)
        return subRegMap[key.."__cap"]
    end

    -- Map params to registers 0..paramCount-1
    for i, arg in ipairs(args) do
        if arg.kind ~= AstKind.VarargExpression then
            subRegMap[tostring(arg.scope)..":"..tostring(arg.id)] = i - 1
        end
    end
    subProto.regNext = paramCount

    local subVarargReg = nil
    if isVararg then
        subVarargReg = self:allocReg(subProto)
        self:emit(subProto, OP.VARARG, subVarargReg, 0, 0)
    end

    if not self.scopeFuncDepths[node] then
        self.scopeFuncDepths[node] = funcDepth + 1
    end

    local outerCapFn    = self._captureFn
    self._captureFn     = isCapture

    self:compileBlock(subProto, node.body, funcDepth + 1, subGetVarReg, subVarargReg)
    self:emit(subProto, OP.RETURN, 0, 1, 0)
    subProto.max_reg = subProto.maxRegSeen + 1
    subProto.nCaptures = #captureList  -- for the VM

    self._captureFn = outerCapFn

    -- Emit CLOSURE into parentProto
    local protoIdx = #parentProto.protos
    parentProto.protos[protoIdx + 1] = subProto

    local dstR = self:allocReg(parentProto)
    self:emit(parentProto, OP.CLOSURE, dstR, protoIdx, #captureList)
    -- Sentinel MOVEs: MOVE 0 parentReg 0
    for _, parentReg in ipairs(captureList) do
        self:emit(parentProto, OP.MOVE, 0, parentReg, 0)
    end

    return dstR, subProto
end

function BC:compileFunctionExpr(proto, expr, funcDepth, getVarReg, varargReg)
    local dstR, _ = self:compileFunctionNode(proto, expr, funcDepth, getVarReg)
    return dstR
end


-- ── public factory ────────────────────────────────────────────────────────────

return {
    new = function()
        return BC:new()
    end,
    BC = BC,
}