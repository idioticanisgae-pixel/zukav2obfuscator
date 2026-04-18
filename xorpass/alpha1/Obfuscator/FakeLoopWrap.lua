

local Ast      = require("ast")
local Scope    = require("scope")


local AstKind  = Ast.AstKind

local FakeLoopWrap       = Step:extend()
FakeLoopWrap.Description = "Wraps random statements in fake single-iteration while-true-break loops (Luarmor-style control flow obfuscation)"
FakeLoopWrap.Name        = "Fake Loop Wrap"

FakeLoopWrap.SettingsDescriptor = {
    -- Probability that any individual eligible statement gets wrapped
    Treshold = {
        type    = "number",
        default = 0.35,
        min     = 0,
        max     = 1,
    },
}

function FakeLoopWrap:init(settings) end

-- These statement kinds must NEVER be wrapped at the top level of a block
-- because doing so would change their semantics.
local UNSAFE_WRAP = {
    [AstKind.ReturnStatement]   = true,
    [AstKind.BreakStatement]    = true,
    [AstKind.ContinueStatement] = true,
}

-- Statement kinds that introduce a real loop body – their direct child blocks
-- must not have statements wrapped (break/continue would escape into our fake loop).
local REAL_LOOP_STMT = {
    [AstKind.WhileStatement]  = true,
    [AstKind.RepeatStatement] = true,
    [AstKind.ForStatement]    = true,
    [AstKind.ForInStatement]  = true,
}

function FakeLoopWrap:apply(ast)
    local treshold = self.Treshold

    visitast(ast,
        -- previsit: tag real-loop body blocks so we skip them below
        function(node, data)
            if REAL_LOOP_STMT[node.kind] and node.body then
                node.body.__insideRealLoop = true
            end
        end,

        -- postvisit: after children processed, wrap eligible statements
        function(node, data)
            if node.kind ~= AstKind.Block then return end
            -- Never wrap inside a real loop's direct body
            if node.__insideRealLoop then return end

            local i = 1
            while i <= #node.statements do
                local stmt = node.statements[i]

                if not UNSAFE_WRAP[stmt.kind] and math.random() <= treshold then
                    -- New scope for the while body, child of the current block scope.
                    -- This means any variable in stmt that references node.scope is
                    -- still accessible (child scopes can see parent scopes).
                    local loopScope = Scope:new(node.scope)

                    local loopBody = Ast.Block(
                        {
                            stmt,
                            Ast.BreakStatement(nil, loopScope),
                        },
                        loopScope
                    )

                    -- WhileStatement(body, condition, parentScope)
                    local whileNode = Ast.WhileStatement(
                        loopBody,
                        Ast.BooleanExpression(true),
                        node.scope
                    )

                    node.statements[i] = whileNode
                    -- i stays the same: we already processed stmt's children
                    -- (postvisit fires after children), so no double-visit.
                end

                i = i + 1
            end
        end
    )
end

return FakeLoopWrap
