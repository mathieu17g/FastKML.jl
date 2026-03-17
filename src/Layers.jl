module Layers

export list_layers, get_layer_names, get_num_layers, get_layer_info, select_layer

using REPL.TerminalMenus
using Base: read  # Import read from Base
import ..Types: KMLFile, LazyKMLFile, Feature, Document, Folder, Placemark
import XML: XML, children, tag, attributes
import ..XMLParsing: extract_text_content_fast
import ..Macros: @find_immediate_child, @for_each_immediate_child, @count_immediate_children

# ──────────────────────────────────────────────────────────────────────────────
# Eager (KMLFile) helpers
# ──────────────────────────────────────────────────────────────────────────────

function _top_level_features(file::KMLFile)::Vector{Feature}
    feats = Feature[c for c in file.children if c isa Feature]
    if isempty(feats)
        for c in file.children
            if (c isa Document || c isa Folder) && c.Features !== nothing
                append!(feats, c.Features)
            end
        end
    end
    feats
end

function _determine_layers(features::Vector{Feature})
    if length(features) == 1
        f = features[1]
        if f isa Document || f isa Folder
            sub = (f.Features !== nothing ? f.Features : Feature[])
            return [x for x in sub if x isa Document || x isa Folder], Placemark[x for x in sub if x isa Placemark], f
        else
            return Feature[], (f isa Placemark ? [f] : Placemark[]), nothing
        end
    else
        return [x for x in features if x isa Document || x isa Folder],
        Placemark[x for x in features if x isa Placemark],
        nothing
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# Lazy (LazyKMLFile) helpers
# ──────────────────────────────────────────────────────────────────────────────

function _find_kml_element(doc::XML.AbstractXMLNode)
    kml_elem = @find_immediate_child doc child (tag(child) == "kml")
    isnothing(kml_elem) && error("No <kml> tag found in LazyKMLFile")
    return kml_elem
end

function _is_feature_tag(tag_name::String)
    tag_name in
    ("Document", "Folder", "Placemark", "NetworkLink", "GroundOverlay", "PhotoOverlay", "ScreenOverlay", "gx:Tour")
end

function _is_container_tag(tag_name::String)
    tag_name in ("Document", "Folder")
end

function _get_name_from_node(node::XML.AbstractXMLNode)
    name_node = @find_immediate_child node child begin
        XML.nodetype(child) === XML.Element && tag(child) == "name"
    end
    
    if name_node !== nothing
        # Found name element, extract text using our existing function
        return extract_text_content_fast(name_node)
    end
    
    return nothing
end

function _lazy_top_level_features(file::LazyKMLFile)
    kml_elem = _find_kml_element(file.root_node)
    features = []

    @for_each_immediate_child kml_elem child begin
        if XML.nodetype(child) === XML.Element
            child_tag = tag(child)
            if _is_feature_tag(child_tag)
                push!(features, child)
            end
        end
    end

    # If no direct features, look inside first container
    if isempty(features)
        first_container = @find_immediate_child kml_elem child begin
            XML.nodetype(child) === XML.Element && _is_container_tag(tag(child))
        end
        
        if first_container !== nothing
            @for_each_immediate_child first_container subchild begin
                if XML.nodetype(subchild) === XML.Element && _is_feature_tag(tag(subchild))
                    push!(features, subchild)
                end
            end
        end
    end

    features
end

# ──────────────────────────────────────────────────────────────────────────────
# Placemark counting functions (recursive)
# ──────────────────────────────────────────────────────────────────────────────

function _count_placemarks_recursive(container::Union{Document, Folder})::Int
    count = 0
    if container.Features !== nothing
        for feat in container.Features
            if feat isa Placemark
                count += 1
            elseif feat isa Document || feat isa Folder
                count += _count_placemarks_recursive(feat)
            end
        end
    end
    return count
end

function _count_placemarks_recursive_lazy(node::XML.AbstractXMLNode)::Int
    count = 0
    @for_each_immediate_child node child begin
        child_tag = tag(child)
        if child_tag == "Placemark"
            count += 1
        elseif _is_container_tag(child_tag)
            # Only recurse if there are element children
            if (@count_immediate_children child c (XML.nodetype(c) === XML.Element)) > 0
                count += _count_placemarks_recursive_lazy(child)
            end
        end
    end
    return count
end

# ──────────────────────────────────────────────────────────────────────────────
# Generic layer info function
# ──────────────────────────────────────────────────────────────────────────────

function get_layer_info(file::Union{KMLFile,LazyKMLFile})
    if file isa LazyKMLFile
        lock(file._lock) do
            # Check cache first
            if file._layer_info_cache !== nothing
                return file._layer_info_cache
            end
            
            # Build layer info
            layer_infos = Tuple{Int,String,Any}[]
            idx_counter = 0
            
            #! LazyKMLFile implementation
            top_feats = _lazy_top_level_features(file)

            if length(top_feats) == 1 && _is_container_tag(tag(top_feats[1]))
                main_container = top_feats[1]
                main_container_name = _get_name_from_node(main_container)

                # Look for sub-containers and placemarks
                has_placemarks = false
                @for_each_immediate_child main_container child begin
                    child_tag = tag(child)
                    if _is_container_tag(child_tag)
                        idx_counter += 1
                        layer_name = _get_name_from_node(child)
                        layer_name = layer_name !== nothing ? layer_name : "<Unnamed Container>"
                        push!(layer_infos, (idx_counter, layer_name, child))
                    elseif child_tag == "Placemark"
                        has_placemarks = true
                    end
                end

                if has_placemarks
                    idx_counter += 1
                    container_desc = main_container_name !== nothing ? main_container_name : "Top Container"
                    push!(layer_infos, (idx_counter, "<Placemarks in $container_desc>", main_container))
                end
            else
                has_top_placemarks = false
                for feat in top_feats
                    feat_tag = tag(feat)
                    if _is_container_tag(feat_tag)
                        idx_counter += 1
                        layer_name = _get_name_from_node(feat)
                        layer_name = layer_name !== nothing ? layer_name : "<Unnamed Container>"
                        push!(layer_infos, (idx_counter, layer_name, feat))
                    elseif feat_tag == "Placemark"
                        has_top_placemarks = true
                    end
                end

                if has_top_placemarks
                    idx_counter += 1
                    # Store the kml element itself as the source for top-level placemarks
                    kml_elem = _find_kml_element(file.root_node)
                    push!(layer_infos, (idx_counter, "<Ungrouped Top-Level Placemarks>", kml_elem))
                end
            end

            # Cache the result
            file._layer_info_cache = layer_infos
            return layer_infos
        end
    else
        # KMLFile branch - no locking needed
        layer_infos = Tuple{Int,String,Any}[]
        idx_counter = 0
        
        #! Eager KMLFile implementation
        top_feats = _top_level_features(file)

        #───────────────────────────────────────────────────────────────────#
        # Scenario 1: Single Top-Level Document/Folder                      #
        #───────────────────────────────────────────────────────────────────#

        if length(top_feats) == 1 && (top_feats[1] isa Document || top_feats[1] isa Folder)
            main_container = top_feats[1]
            if main_container.Features !== nothing
                for feat in main_container.Features
                    if feat isa Document || feat isa Folder
                        idx_counter += 1
                        layer_name = feat.name !== nothing ? feat.name : "<Unnamed Container>"
                        push!(layer_infos, (idx_counter, layer_name, feat))
                    end
                end
                # Check for direct placemarks in this main container
                direct_pms_in_container = [f for f in main_container.Features if f isa Placemark]
                if !isempty(direct_pms_in_container)
                    idx_counter += 1
                    push!(
                        layer_infos,
                        (
                            idx_counter,
                            "<Placemarks in $(main_container.name !== nothing ? main_container.name : "Top Container")>",
                            direct_pms_in_container,
                        ),
                    )
                end
            end

            #───────────────────────────────────────────────────────────────────#
            # Scenario 2: Multiple Top-Level Features or Direct Placemarks      #
            #───────────────────────────────────────────────────────────────────#

        else
            # Top-level containers (Documents/Folders)
            for feat in top_feats
                if feat isa Document || feat isa Folder
                    idx_counter += 1
                    layer_name = feat.name !== nothing ? feat.name : "<Unnamed Container>"
                    push!(layer_infos, (idx_counter, layer_name, feat))
                end
            end
            # Top-level direct placemarks
            direct_top_pms = [f for f in top_feats if f isa Placemark]
            if !isempty(direct_top_pms)
                idx_counter += 1
                push!(layer_infos, (idx_counter, "<Ungrouped Top-Level Placemarks>", direct_top_pms))
            end
        end
        
        return layer_infos
    end
end

# ──────────────────────────────────────────────────────────────────────────────
# Layer selection
# ──────────────────────────────────────────────────────────────────────────────

function select_layer(file::Union{KMLFile,LazyKMLFile}, layer_spec::Union{Nothing,String,Integer})
    layer_options = get_layer_info(file)

    if isempty(layer_options)
        return file isa KMLFile ? Feature[] : nothing
    end

    if layer_spec isa String
        for (_, name, source) in layer_options
            if name == layer_spec
                return source # Return the source (Document, Folder, or Placemark vector)
            end
        end
        error("Layer \"$layer_spec\" not found by name. Available: $(join([opt[2] for opt in layer_options], ", "))")
    elseif layer_spec isa Integer
        if 1 <= layer_spec <= length(layer_options)
            return layer_options[layer_spec][3] # Return the source (Document, Folder, or Placemark vector)
        else
            # Generate a detailed error message with all available layers
            layer_details_parts = String[]
            # Add header for available layers
            for (idx, name, origin) in layer_options
                item_count_str = ""
                if origin isa Vector{Placemark}
                    item_count_str = " ($(length(origin)) placemarks)"
                elseif origin isa Document || origin isa Folder
                    num_placemarks = _count_placemarks_recursive(origin)
                    item_count_str = " ($num_placemarks placemarks)"
                elseif origin isa XML.AbstractXMLNode
                    placemark_count = _count_placemarks_recursive_lazy(origin)
                    item_count_str = " ($placemark_count placemarks)"
                end
                push!(layer_details_parts, "  [$idx] $name$item_count_str")
            end
            layer_details_str = join(layer_details_parts, "\n")
            error(
                "Layer index $layer_spec out of bounds. Must be between 1 and $(length(layer_options)).\nAvailable layers:\n$layer_details_str",
            )
        end
    elseif layer_spec === nothing # No specific layer requested
        if length(layer_options) == 1
            return layer_options[1][3]
        end
        # If multiple layers, prompt user for selection
        # Use REPL.TerminalMenus for interactive selection
        opts = [opt[2] for opt in layer_options]
        interactive = (stdin isa Base.TTY) && (stdout isa Base.TTY) && isinteractive()
        if interactive
            menu = RadioMenu(opts; pagesize = min(10, length(opts)))
            choice_idx = request("Select a layer:", menu)
            choice_idx == -1 && error("Layer selection cancelled.")
            return layer_options[choice_idx][3]
        else
            @warn "Multiple layers available. Picking first: \"$(layer_options[1][2])\"."
            return layer_options[1][3]
        end
    end
    return file isa KMLFile ? Feature[] : nothing
end

# ──────────────────────────────────────────────────────────────────────────────
# Public API functions
# ──────────────────────────────────────────────────────────────────────────────

"""
    list_layers(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})

Prints a list of available "layers" found within a KML file to the console.
"""
function list_layers(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})
    file = if kml_input isa AbstractString
        # Try lazy loading first for efficiency
        read(kml_input, LazyKMLFile)
    else
        kml_input
    end

    println("Available layers:")
    layer_infos = get_layer_info(file)

    if isempty(layer_infos)
        println("  No distinct layers found (or KML contains no Placemarks in common structures).")
        return
    end

    for (idx, name, origin) in layer_infos
        item_count_str = ""
        if origin isa Vector{Placemark}
            item_count_str = " ($(length(origin)) placemarks)"
        elseif origin isa Document || origin isa Folder
            num_placemarks = _count_placemarks_recursive(origin)
            item_count_str = " ($num_placemarks placemarks)"
        elseif origin isa XML.AbstractXMLNode
            placemark_count = _count_placemarks_recursive_lazy(origin)
            item_count_str = " ($placemark_count placemarks)"
        end
        println("  [$idx] $name$item_count_str")
    end
end

"""
    get_layer_names(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})::Vector{String}

Returns an array of strings containing the names of available "layers"
found within a KML file.
"""
function get_layer_names(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})::Vector{String}
    file = if kml_input isa AbstractString
        read(kml_input, LazyKMLFile)
    else
        kml_input
    end
    layer_infos = get_layer_info(file)

    if isempty(layer_infos)
        return String[]
    end

    return [name for (_, name, _) in layer_infos]
end

"""
    get_num_layers(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})::Int

Returns the number of available "layers" found within a KML file.
"""
function get_num_layers(kml_input::Union{AbstractString,KMLFile,LazyKMLFile})::Int
    file = if kml_input isa AbstractString
        read(kml_input, LazyKMLFile)
    else
        kml_input
    end
    layer_infos = get_layer_info(file)
    return length(layer_infos)
end

end # module Layers