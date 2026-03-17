# src/macros.jl
module Macros

export @for_each_immediate_child, @find_immediate_child, @count_immediate_children

using XML

"""
    @for_each_immediate_child node child body

Iterate over immediate children of a node with zero overhead.
Completely inlines the iteration code at compile time.
"""
macro for_each_immediate_child(node_expr, child_var, body)
    quote
        let _node = $(esc(node_expr))
            if _node isa XML.LazyNode
                let _initial_depth = XML.depth(_node),
                    _target_depth = _initial_depth + 1,
                    _current = XML.next(_node)
                    
                    while !isnothing(_current)
                        _raw = _current.raw
                        _cur_depth = XML.depth(_raw)
                        
                        # Single stop condition
                        if _cur_depth <= _initial_depth
                            break
                        end
                        
                        # Process only immediate children
                        if _cur_depth == _target_depth
                            let $(esc(child_var)) = _current
                                $(esc(body))
                            end
                            # After processing, we know next() is safe
                            _current = XML.next(_current)
                        elseif _cur_depth > _target_depth
                            # Skip entire subtree efficiently
                            while true
                                _current = XML.next(_current)
                                if isnothing(_current) || XML.depth(_current.raw) <= _target_depth
                                    break
                                end
                            end
                        else
                            # Should not happen, but advance anyway
                            _current = XML.next(_current)
                        end
                    end
                end
            else
                # Regular Node - use children()
                for $(esc(child_var)) in XML.children(_node)
                    $(esc(body))
                end
            end
        end
        nothing
    end
end

"""
    @find_immediate_child node child condition

Find the first immediate child matching the condition.
Returns the child or nothing. Zero overhead implementation.
"""
macro find_immediate_child(node_expr, child_var, condition)
    quote
        let _node = $(esc(node_expr))
            if _node isa XML.LazyNode
                let _initial_depth = XML.depth(_node),
                    _target_depth = _initial_depth + 1,
                    _current = XML.next(_node),
                    _result = nothing
                    
                    while !isnothing(_current) && isnothing(_result)
                        _raw = _current.raw
                        _cur_depth = XML.depth(_raw)
                        
                        # Single stop condition
                        if _cur_depth <= _initial_depth
                            break
                        end
                        
                        # Check immediate children only
                        if _cur_depth == _target_depth
                            let $(esc(child_var)) = _current
                                if $(esc(condition))
                                    _result = _current
                                end
                            end
                            # If not found, continue
                            if isnothing(_result)
                                _current = XML.next(_current)
                            end
                        elseif _cur_depth > _target_depth
                            # Skip entire subtree efficiently
                            while true
                                _current = XML.next(_current)
                                if isnothing(_current) || XML.depth(_current.raw) <= _target_depth
                                    break
                                end
                            end
                        else
                            # Should not happen, but advance anyway
                            _current = XML.next(_current)
                        end
                    end
                    _result
                end
            else
                # Regular Node
                let _result = nothing
                    for $(esc(child_var)) in XML.children(_node)
                        if $(esc(condition))
                            _result = $(esc(child_var))
                            break
                        end
                    end
                    _result
                end
            end
        end
    end
end

"""
    @count_immediate_children node child condition

Count immediate children matching the condition.
Zero overhead implementation.
"""
macro count_immediate_children(node_expr, child_var, condition)
    quote
        let _node = $(esc(node_expr))
            if _node isa XML.LazyNode
                let _initial_depth = XML.depth(_node),
                    _target_depth = _initial_depth + 1,
                    _current = XML.next(_node),
                    _count = 0
                    
                    while !isnothing(_current)
                        _raw = _current.raw
                        _cur_depth = XML.depth(_raw)
                        
                        # Single stop condition
                        if _cur_depth <= _initial_depth
                            break
                        end
                        
                        # Count immediate children only
                        if _cur_depth == _target_depth
                            let $(esc(child_var)) = _current
                                if $(esc(condition))
                                    _count += 1
                                end
                            end
                            # Continue to next
                            _current = XML.next(_current)
                        elseif _cur_depth > _target_depth
                            # Skip entire subtree efficiently
                            while true
                                _current = XML.next(_current)
                                if isnothing(_current) || XML.depth(_current.raw) <= _target_depth
                                    break
                                end
                            end
                        else
                            # Should not happen, but advance anyway
                            _current = XML.next(_current)
                        end
                    end
                    _count
                end
            else
                # Regular Node
                let _count = 0
                    for $(esc(child_var)) in XML.children(_node)
                        if $(esc(condition))
                            _count += 1
                        end
                    end
                    _count
                end
            end
        end
    end
end

end # module Macros