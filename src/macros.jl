# src/macros.jl
module Macros

export @for_each_immediate_child, @find_immediate_child, @count_immediate_children

using XML

"""
    @for_each_immediate_child node child body

Iterate over immediate children of a node with zero overhead.
Completely inlines the iteration code at compile time.

Uses `XML.children(node)` which is polymorphic over `XML.Node` (eager,
already has its children materialized) and `XML.LazyNode` (eager-collected
on demand from the tokenizer in v0.4). The iteration cost is one
`Vector{<:Any}` allocation per call for LazyNode parents — acceptable
for FastKML's per-Placemark walk pattern.
"""
macro for_each_immediate_child(node_expr, child_var, body)
    quote
        for $(esc(child_var)) in XML.children($(esc(node_expr)))
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
            for $(esc(child_var)) in XML.children($(esc(node_expr)))
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
            for $(esc(child_var)) in XML.children($(esc(node_expr)))
                if $(esc(condition))
                    _count += 1
                end
            end
            _count
        end
    end
end

end # module Macros
