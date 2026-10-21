module FastKMLREPLExt

using FastKML
using REPL.TerminalMenus: RadioMenu, request

# The menu `select_layer` opens when several layers match and the session is an interactive
# terminal. `select_layer` loads REPL when it needs the menu, which loads this extension.
function FastKML.Layers._choose_layer_interactively(opts::Vector{String})
    menu = RadioMenu(opts; pagesize = min(10, length(opts)))
    return request("Select a layer:", menu)
end

end # module FastKMLREPLExt
