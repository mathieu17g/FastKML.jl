using FastKML
using GeoInterface
using Tables
using Test
using XML
using StaticArrays  # Add this import



@testset "Issue Coverage" begin
    # https://github.com/JuliaComputing/FastKML.jl/issues/8
    @test_warn "Unhandled Tag" read(joinpath(@__DIR__, "outside_spec.kml"), KMLFile)

    # https://github.com/JuliaComputing/FastKML.jl/issues/12
    @test read(joinpath(@__DIR__, "issue12.kml"), KMLFile) isa KMLFile
end

@testset "Empty Constructors" begin
    for T in FastKML.all_concrete_subtypes(FastKML.Object)
        @test T() isa T
    end
    @testset "Empty constructor roundtrips with XML.Node" begin
        for T in FastKML.all_concrete_subtypes(FastKML.Object)
            o = T()
            n = FastKML.to_xml(o)
            tag = XML.tag(n)
            if !isnothing(tag)
                @test occursin(tag, replace(string(T), '_' => ':'))
            end
            o2 = FastKML.object(n)
            @test o2 isa T
            @test o == o2
        end
    end
end


@testset "GeoInterface" begin
    # Use SVector for coordinates instead of tuples
    @test GeoInterface.testgeometry(Point(coordinates = SVector(0.0, 0.0)))
    @test GeoInterface.testgeometry(LineString(coordinates = [SVector(0.0, 0.0), SVector(1.0, 1.0)]))
    @test GeoInterface.testgeometry(LinearRing(coordinates = [SVector(0.0, 0.0), SVector(1.0, 1.0), SVector(2.0, 2.0)]))

    p = Polygon(
        outerBoundaryIs = LinearRing(
            coordinates = [SVector(0.0, 0.0), SVector(1.0, 1.0), SVector(2.0, 2.0), SVector(0.0, 0.0)],
        ),
        innerBoundaryIs = [
            LinearRing(coordinates = [SVector(0.5, 0.5), SVector(0.7, 0.7), SVector(0.0, 0.0), SVector(0.5, 0.5)]),
        ],
    )
    @test GeoInterface.testgeometry(p)

    # Create a Placemark with some properties to avoid empty tuple issue
    placemark = Placemark(name = "Test Placemark", description = "A test placemark", Geometry = p)
    @test GeoInterface.testfeature(placemark)

    # Test that the geometry is correctly extracted
    @test GeoInterface.geometry(placemark) === p

    # Test that properties are correctly extracted
    props = GeoInterface.properties(placemark)
    @test props.name == "Test Placemark"
    @test props.description == "A test placemark"
end

@testset "KMLFile roundtrip" begin
    file = read(joinpath(@__DIR__, "example.kml"), KMLFile)
    @test file isa KMLFile

    temp = tempname() * ".kml"

    # Write the file
    FastKML.write(temp, file)
    
    # Read it back
    file2 = read(temp, KMLFile)
    
    @test file == file2
    
    # Clean up - wrapped in try/catch for Windows
    try
        rm(temp, force = true)
    catch
        # Ignore cleanup errors
    end
end

@testset "coordinates" begin
    # `coordinates` are single coordinate (2D or 3D)
    s = "<Point><coordinates>1,2,3</coordinates></Point>"
    p = FastKML.object(XML.parse(s, XML.Node)[1])
    @test p isa Point
    @test p.coordinates isa SVector{3,Float64}
    @test p.coordinates == SVector(1.0, 2.0, 3.0)

    # `coordinates` are vector of coordinates
    s = "<LineString><coordinates>1,2,3 4,5,6</coordinates></LineString>"
    ls = FastKML.object(XML.parse(s, XML.Node)[1])
    @test ls isa LineString
    @test ls.coordinates isa Vector{SVector{3,Float64}}
    @test length(ls.coordinates) == 2
    @test ls.coordinates[1] == SVector(1.0, 2.0, 3.0)
    @test ls.coordinates[2] == SVector(4.0, 5.0, 6.0)
end

# Add tests for new features
@testset "Lazy Loading" begin
    lazy_file = read(joinpath(@__DIR__, "example.kml"), LazyKMLFile)
    @test lazy_file isa LazyKMLFile

    # Test conversion to KMLFile
    kml_file = KMLFile(lazy_file)
    @test kml_file isa KMLFile
end

@testset "Navigation" begin
    file = read(joinpath(@__DIR__, "example.kml"), KMLFile)

    # Test children function
    kids = FastKML.children(file)
    @test length(kids) > 0

    # Test iteration
    count = 0
    for child in file
        count += 1
    end
    @test count == length(file)

    # Test indexing
    @test file[1] == kids[1]
end

@testset "Coordinate Parsing" begin
    # Test various coordinate formats
    coords = FastKML.Coordinates.parse_coordinates_automa("1,2")
    @test coords == [SVector(1.0, 2.0)]

    coords = FastKML.Coordinates.parse_coordinates_automa("1,2,3")
    @test coords == [SVector(1.0, 2.0, 3.0)]

    coords = FastKML.Coordinates.parse_coordinates_automa("1,2 3,4")
    @test coords == [SVector(1.0, 2.0), SVector(3.0, 4.0)]

    coords = FastKML.Coordinates.parse_coordinates_automa("1,2,3 4,5,6")
    @test coords == [SVector(1.0, 2.0, 3.0), SVector(4.0, 5.0, 6.0)]

    # Test with whitespace variations
    coords = FastKML.Coordinates.parse_coordinates_automa("  1.5 , 2.5  \n  3.5 , 4.5  ")
    @test coords == [SVector(1.5, 2.5), SVector(3.5, 4.5)]

    # Non-conformant input — comma-only delimiters with no whitespace between
    # tuples. Encountered in real-world KMLs produced by tools like KMLer
    # (e.g. ESDAC's USEDO.kmz). FastKML's parser is intentionally lenient and
    # should still recover the correct triplets.
    coords = FastKML.Coordinates.parse_coordinates_automa("28.25,69.06,0,28.26,69.07,0,28.27,69.08,0")
    @test coords == [SVector(28.25, 69.06, 0.0), SVector(28.26, 69.07, 0.0), SVector(28.27, 69.08, 0.0)]

    # Same leniency for 2D pairs
    coords = FastKML.Coordinates.parse_coordinates_automa("1.0,2.0,3.0,4.0")
    @test coords == [SVector(1.0, 2.0), SVector(3.0, 4.0)]
end

@testset "Utils" begin
    eg = joinpath(@__DIR__, "example.kml")
    file = read(eg, KMLFile)

    # ── find_placemarks ──
    pms = FastKML.Utils.find_placemarks(file)
    @test length(pms) == 3
    @test all(p isa FastKML.Placemark for p in pms)
    @test length(FastKML.Utils.find_placemarks(file; name_pattern = r"Central")) == 1
    @test length(FastKML.Utils.find_placemarks(file; name_pattern = "Tunnel")) == 1
    @test length(FastKML.Utils.find_placemarks(file; has_geometry = true)) == 3
    @test length(FastKML.Utils.find_placemarks(file; has_geometry = false)) == 0

    # ── count_features ──
    counts = FastKML.Utils.count_features(file)
    @test counts[:Placemark] == 3
    @test counts[:Folder] == 0

    pt_pm   = first(p for p in pms if p.name == "Time Square")
    poly_pm = first(p for p in pms if p.name == "Central Park")
    line_pm = first(p for p in pms if p.name == "Lincoln Tunnel")

    # ── get_bounds: Point / Polygon / LineString / container ──
    pt_b = FastKML.Utils.get_bounds(pt_pm.Geometry)
    @test pt_b isa NTuple{4, Float64}
    @test pt_b[1] == pt_b[3]                       # min_lon == max_lon for a point
    @test pt_b[2] == pt_b[4]

    poly_b = FastKML.Utils.get_bounds(poly_pm.Geometry)
    @test poly_b[1] < poly_b[3]                    # spans range in lon
    @test poly_b[2] < poly_b[4]                    # spans range in lat

    line_b = FastKML.Utils.get_bounds(line_pm.Geometry)
    @test line_b isa NTuple{4, Float64}

    file_b = FastKML.Utils.get_bounds(file)
    @test file_b isa NTuple{4, Float64}

    # ── extract_path ──
    path = FastKML.Utils.extract_path(line_pm.Geometry)
    @test path isa Vector{Tuple{Float64, Float64}}
    @test length(path) == 4                        # Lincoln Tunnel: 4 coords

    # Empty LineString
    @test FastKML.Utils.extract_path(FastKML.LineString(coordinates = nothing)) == Tuple{Float64, Float64}[]

    # ── extract_styles ──
    styles = FastKML.Utils.extract_styles(file)
    @test length(styles) == 3                      # example.kml has 3 Style entries

    # ── get_metadata ──
    meta = FastKML.Utils.get_metadata(pt_pm)
    @test meta isa Dict{Symbol, Any}
    @test meta[:name] == "Time Square"
    @test meta[:geometry_type] == "Point"

    # ── haversine_distance: NYC ↔ LA ≈ 3935 km ──
    nyc = SVector(-74.006, 40.7128, 0.0)
    la  = SVector(-118.243, 34.0522, 0.0)
    @test 3.93e6 < FastKML.Utils.haversine_distance(nyc, la) < 3.95e6
    @test FastKML.Utils.haversine_distance(nyc, nyc) ≈ 0.0 atol = 1e-9

    # ── path_length ──
    @test FastKML.Utils.path_length(line_pm.Geometry) > 0.0
    @test FastKML.Utils.path_length(FastKML.LineString(coordinates = nothing)) == 0.0

    # ── unwrap_single_part_multigeometry ──
    @test FastKML.unwrap_single_part_multigeometry(nothing) === nothing
    @test FastKML.unwrap_single_part_multigeometry(missing) === missing
    @test FastKML.unwrap_single_part_multigeometry(pt_pm.Geometry) === pt_pm.Geometry

    mg_single = FastKML.MultiGeometry(Geometries = [pt_pm.Geometry])
    @test FastKML.unwrap_single_part_multigeometry(mg_single) === pt_pm.Geometry

    mg_multi = FastKML.MultiGeometry(Geometries = [pt_pm.Geometry, line_pm.Geometry])
    @test FastKML.unwrap_single_part_multigeometry(mg_multi) === mg_multi

    # ── merge_kml_files: two single-Placemark files combine to one with 2 ──
    file_a = parse(KMLFile, """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <name>Doc A</name>
        <Placemark><name>From A</name><Point><coordinates>0,0,0</coordinates></Point></Placemark>
      </Document>
    </kml>
    """)
    file_b = parse(KMLFile, """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <name>Doc B</name>
        <Placemark><name>From B</name><Point><coordinates>1,1,0</coordinates></Point></Placemark>
      </Document>
    </kml>
    """)
    merged = FastKML.Utils.merge_kml_files(file_a, file_b; name = "Merged")
    @test merged isa KMLFile
    @test FastKML.Utils.count_features(merged)[:Placemark] == 2
end

@testset "Layers" begin
    eg = joinpath(@__DIR__, "example.kml")

    # ── Single-layer file (example.kml: 1 Document, 3 Placemarks, no Folders) ──

    # Path-based API parses internally and returns the same as the typed paths
    @test get_num_layers(eg) == 1
    @test length(get_layer_names(eg)) == 1
    @test get_layer_names(eg)[1] isa String

    eager = read(eg, KMLFile)
    @test get_num_layers(eager) == 1
    @test get_layer_names(eager) == get_layer_names(eg)

    lazy = read(eg, LazyKMLFile)
    @test get_num_layers(lazy) == 1
    @test get_layer_names(lazy) == get_layer_names(eg)

    # get_layer_info returns Vector{Tuple{Int, String, Any}}
    info = FastKML.Layers.get_layer_info(lazy)
    @test length(info) == 1
    @test info[1][1] == 1                         # idx
    @test info[1][2] isa AbstractString           # name

    # select_layer by index, by name, and error paths
    @test FastKML.Layers.select_layer(lazy, 1) !== nothing
    @test FastKML.Layers.select_layer(lazy, get_layer_names(lazy)[1]) !== nothing
    @test_throws ErrorException FastKML.Layers.select_layer(lazy, 99)
    @test_throws ErrorException FastKML.Layers.select_layer(lazy, "no_such_layer")

    # list_layers prints diagnostic info to stdout and returns nothing —
    # verify it doesn't throw. (We let the println noise hit the test
    # runner output rather than fight Julia 1.12's `redirect_stdout`
    # restrictions on `IOBuffer`.)
    @test list_layers(eg) === nothing

    # ── Multi-layer file (synthetic, 2 Folders inside 1 Document) ──

    multi_kml = """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <name>Top Document</name>
        <Folder>
          <name>Layer A</name>
          <Placemark><name>P1</name><Point><coordinates>0,0,0</coordinates></Point></Placemark>
        </Folder>
        <Folder>
          <name>Layer B</name>
          <Placemark><name>P2</name><Point><coordinates>1,1,0</coordinates></Point></Placemark>
          <Placemark><name>P3</name><Point><coordinates>2,2,0</coordinates></Point></Placemark>
        </Folder>
      </Document>
    </kml>
    """
    multi_eager = parse(KMLFile, multi_kml)
    multi_lazy  = parse(LazyKMLFile, multi_kml)

    @test get_num_layers(multi_eager) == 2
    @test get_num_layers(multi_lazy) == 2

    lazy_names = get_layer_names(multi_lazy)
    @test length(lazy_names) == 2
    @test "Layer A" in lazy_names
    @test "Layer B" in lazy_names

    # Select by name and by index
    @test FastKML.Layers.select_layer(multi_lazy, "Layer A") !== nothing
    @test FastKML.Layers.select_layer(multi_lazy, "Layer B") !== nothing
    @test FastKML.Layers.select_layer(multi_lazy, 1) !== nothing
    @test FastKML.Layers.select_layer(multi_lazy, 2) !== nothing
end

@testset "PlacemarkTable / Tables.jl interface" begin
    eg = joinpath(@__DIR__, "example.kml")

    # ── Construction from each input type ──
    t_path  = PlacemarkTable(eg)
    t_eager = PlacemarkTable(read(eg, KMLFile))
    t_lazy  = PlacemarkTable(read(eg, LazyKMLFile))

    # Tables.jl interface trait methods
    @test Tables.istable(typeof(t_path))
    @test Tables.istable(KMLFile)
    @test Tables.istable(LazyKMLFile)
    @test Tables.rowaccess(typeof(t_path))

    # Schema is name / description / geometry
    sch = Tables.schema(t_path)
    @test sch.names == (:name, :description, :geometry)
    @test sch.types[1] === String
    @test sch.types[2] === String

    # ── Row contents on example.kml: 3 Placemarks (Point / Polygon / LineString) ──
    rows_lazy = collect(Tables.rows(t_path))
    @test length(rows_lazy) == 3
    @test Set(r.name for r in rows_lazy) ==
          Set(["Time Square", "Central Park", "Lincoln Tunnel"])
    geom_types = Set(typeof(r.geometry) for r in rows_lazy)
    @test FastKML.Point     in geom_types
    @test FastKML.LineString in geom_types
    @test FastKML.Polygon    in geom_types

    # Eager path returns the same names (different geometry objects but same logical data)
    rows_eager = collect(Tables.rows(t_eager))
    @test length(rows_eager) == 3
    @test Set(r.name for r in rows_eager) == Set(r.name for r in rows_lazy)

    # ── Multi-layer file with `layer = ` selection ──
    multi_kml = """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <name>Multi</name>
        <Folder>
          <name>Layer A</name>
          <Placemark><name>P1</name><Point><coordinates>0,0,0</coordinates></Point></Placemark>
        </Folder>
        <Folder>
          <name>Layer B</name>
          <Placemark><name>P2</name><Point><coordinates>1,1,0</coordinates></Point></Placemark>
          <Placemark><name>P3</name><Point><coordinates>2,2,0</coordinates></Point></Placemark>
        </Folder>
      </Document>
    </kml>
    """
    multi_lazy = parse(LazyKMLFile, multi_kml)

    rows_a = collect(Tables.rows(PlacemarkTable(multi_lazy; layer = 1)))
    @test length(rows_a) == 1
    @test rows_a[1].name == "P1"

    rows_b = collect(Tables.rows(PlacemarkTable(multi_lazy; layer = 2)))
    @test length(rows_b) == 2
    @test Set(r.name for r in rows_b) == Set(["P2", "P3"])

    # Layer selection by name (exercises Layers.select_layer's String branch)
    rows_by_name = collect(Tables.rows(PlacemarkTable(multi_lazy; layer = "Layer A")))
    @test length(rows_by_name) == 1
    @test rows_by_name[1].name == "P1"

    # ── MultiGeometry path coverage in parse_geometry_lazy ──
    multi_geom_kml = """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>MG</name>
          <MultiGeometry>
            <Point><coordinates>0,0,0</coordinates></Point>
            <Point><coordinates>1,1,0</coordinates></Point>
          </MultiGeometry>
        </Placemark>
      </Document>
    </kml>
    """
    mg_rows = collect(Tables.rows(PlacemarkTable(parse(LazyKMLFile, multi_geom_kml))))
    @test length(mg_rows) == 1
    @test mg_rows[1].geometry isa FastKML.MultiGeometry

    # ── simplify_single_parts: single-child MultiGeometry should unwrap to inner geometry ──
    single_mg_kml = """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>SingleMG</name>
          <MultiGeometry>
            <Point><coordinates>5,5,0</coordinates></Point>
          </MultiGeometry>
        </Placemark>
      </Document>
    </kml>
    """
    smg = parse(LazyKMLFile, single_mg_kml)
    no_simplify = collect(Tables.rows(PlacemarkTable(smg)))
    simplified  = collect(Tables.rows(PlacemarkTable(smg; simplify_single_parts = true)))
    @test no_simplify[1].geometry isa FastKML.MultiGeometry
    @test simplified[1].geometry  isa FastKML.Point
end

@testset "HTML entity decoding" begin
    decode = FastKML.HtmlEntities.decode_named_entities

    # Named entities are decoded
    @test decode("&amp;") == "&"
    @test decode("&lt;a&amp;b&gt;") == "<a&b>"
    @test decode("&le;") == "≤"

    # Numeric entities and unknown names are copied verbatim (per docstring)
    @test decode("&#65;") == "&#65;"
    @test decode("&unknown;") == "&unknown;"

    # Plain text passes through
    @test decode("hello world") == "hello world"
    @test decode("") == ""

    # Multi-byte UTF-8 in the input must NOT trip Julia's char-boundary
    # validation when a token span ends inside a multi-byte char. This case
    # was triggered by EPA's national_frs.kmz, where descriptions contain
    # non-breaking spaces (U+00A0, 2 bytes in UTF-8) adjacent to entities.
    @test decode("foo &amp;bar") == "foo &bar"
    @test decode("≤&amp;≥") == "≤&≥"
    @test decode("a b") == "a b"  # multi-byte char with no entities
end