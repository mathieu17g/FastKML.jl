# src/macros.jl
module Macros

export @for_each_immediate_child, @find_immediate_child, @count_immediate_children

using XML

# Polymorphic child iteration helper.
# - `Node` (eager): `children(n)` is a field accessor returning the existing
#   `Vector{Node}` — zero allocations.
# - `LazyNode` (v0.4): `eachchildnode(n)` returns a streaming iterator that
#   yields one `LazyNode` at a time without materializing a Vector. Critical
#   for FastKML's deep+repeated walks where `children(::LazyNode)` would
#   otherwise allocate one Vector per visited element.
@inline _children_iter(n::XML.Node) = XML.children(n)
@inline _children_iter(n::XML.LazyNode) = XML.eachchildnode(n)

"""
    @for_each_immediate_child node child body

Iterate over immediate children of a node with zero overhead.
Completely inlines the iteration code at compile time.
"""
macro for_each_immediate_child(node_expr, child_var, body)
    quote
        for $(esc(child_var)) in $(@__MODULE__)._children_iter($(esc(node_expr)))
            $(esc(body))
        end
        nothing
    end
end

"""
    @find_immediate_child node child condition

Find the first immediate child matching the condition.
Returns the child or `nothing`.
"""
macro find_immediate_child(node_expr, child_var, condition)
    quote
        let _result = nothing
            for $(esc(child_var)) in $(@__MODULE__)._children_iter($(esc(node_expr)))
                if $(esc(condition))
                    _result = $(esc(child_var))
                    break
                end
            end
            _result
        end
    end
end

"""
    @count_immediate_children node child condition

Count immediate children matching the condition.
"""
macro count_immediate_children(node_expr, child_var, condition)
    quote
        let _count = 0
            for $(esc(child_var)) in $(@__MODULE__)._children_iter($(esc(node_expr)))
                if $(esc(condition))
                    _count += 1
                end
            end
            _count
        end
    end
end

end # module Macros
