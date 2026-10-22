using FastKML
using DataFrames
using Dates
using GeoInterface
using Logging
using Tables
using Test
using TimeZones
using XML
using StaticArrays  # Add this import
using ZipArchives
import InteractiveUtils
import REPL  # loads FastKMLREPLExt



@testset "Issue Coverage" begin
    # https://github.com/JuliaComputing/FastKML.jl/issues/8
    @test_warn "Unhandled Tag" read(joinpath(@__DIR__, "outside_spec.kml"), KMLFile)

    # https://github.com/JuliaComputing/FastKML.jl/issues/12
    @test read(joinpath(@__DIR__, "issue12.kml"), KMLFile) isa KMLFile
end

@testset "Empty Constructors" begin
    # The KML types are found by scanning FastKML's own modules. The list must be the one
    # `InteractiveUtils.subtypes` gives, order included: tag registration follows it.
    reference(T) = mapreduce(S -> isabstracttype(S) ? reference(S) : DataType[S], vcat,
                             InteractiveUtils.subtypes(T); init = DataType[])
    @test !isempty(FastKML.all_concrete_subtypes(FastKML.KMLElement))
    @test FastKML.all_concrete_subtypes(FastKML.KMLElement) == reference(FastKML.KMLElement)

    for T in FastKML.all_concrete_subtypes(FastKML.KMLElement)
        @test T() isa T
    end
    @testset "Empty constructor roundtrips with XML.Node" begin
        for T in FastKML.all_concrete_subtypes(FastKML.KMLElement)
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

@testset "Exported names" begin
    # A name exported by both FastKML and Base, bound to different things, is ambiguous after
    # `using FastKML`: an error under Julia 1.13, a warning under 1.10.
    clashes = filter(names(FastKML)) do n
        Base.isexported(FastKML, n) && Base.isexported(Base, n) &&
            !(isdefined(FastKML, n) && getglobal(FastKML, n) === getglobal(Base, n))
    end
    @test isempty(clashes)

    code = "using FastKML; print(size([1, 2]))"
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
    @test read(cmd, String) == "(2,)"
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

    # Signs, exponents, bare points and special values read alike under Parsers 2 and 3
    coords = FastKML.Coordinates.parse_coordinates_automa("+1,-2.25,1e3 .5,5.,-0")
    @test coords == [SVector(1.0, -2.25, 1000.0), SVector(0.5, 5.0, -0.0)]
    coords = FastKML.Coordinates.parse_coordinates_automa("NaN,Inf,-inf")
    @test isnan(coords[1][1]) && coords[1][2] == Inf && coords[1][3] == -Inf

    # A token that is not a number raises; the exception type depends on the Parsers version
    @test_throws Exception FastKML.Coordinates.parse_coordinates_automa("abc,1")
    @test_throws Exception FastKML.Coordinates.parse_coordinates_automa("1.2.3,1")
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

    # Several layers and none requested: outside an interactive terminal session, the first
    # layer is used, with a warning.
    first_layer = @test_logs (:warn, r"Multiple layers available") FastKML.Layers.select_layer(multi_lazy, nothing)
    @test first_layer == FastKML.Layers.select_layer(multi_lazy, 1)

    # ── Placemarks held next to sub-containers ──
    # They form a layer of their own, after the containers' layers; a sub-container's
    # placemarks belong to its layer only. Both reading modes must agree.
    mixed_kml = """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <name>Mixed</name>
        <Placemark><name>D1</name><Point><coordinates>0,0</coordinates></Point></Placemark>
        <Folder>
          <name>Sub</name>
          <Placemark><name>S1</name><Point><coordinates>1,1</coordinates></Point></Placemark>
        </Folder>
        <Placemark><name>D2</name><Point><coordinates>2,2</coordinates></Point></Placemark>
      </Document>
    </kml>
    """
    loose_kml = """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Folder>
        <name>F</name>
        <Placemark><name>F1</name><Point><coordinates>0,0</coordinates></Point></Placemark>
      </Folder>
      <Placemark><name>T1</name><Point><coordinates>1,1</coordinates></Point></Placemark>
    </kml>
    """
    row_names(file, layer) = [r.name for r in Tables.rows(PlacemarkTable(file; layer))]
    for (kml, names, rows) in ((mixed_kml, ["Sub", "<Placemarks in Mixed>"], [["S1"], ["D1", "D2"]]),
                               (loose_kml, ["F", "<Ungrouped Top-Level Placemarks>"], [["F1"], ["T1"]]))
        for file in (parse(KMLFile, kml), parse(LazyKMLFile, kml))
            @test get_layer_names(file) == names
            @test [row_names(file, k) for k in 1:2] == rows
            @test row_names(file, :all) == reduce(vcat, rows)
            # The layer list of an out-of-range error counts the placemarks of each layer.
            message = try FastKML.Layers.select_layer(file, 3) catch e; e.msg end
            @test occursin("[2] $(names[2]) ($(length(rows[2])) placemarks)", message)
        end
    end
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

    # ── MultiGeometry rows ──
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

    # ── A LazyKMLFile is read with one forward XML.Cursor per layer ──
    # Its rows must be those of the LazyNode walk, kept as the reference for this check.
    TB = FastKML.TablesBridge
    edge_kml = """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
      <Document>
        <Folder>
          <name>Cases</name>
          <Placemark>
            <name>split <![CDATA[cdata]]> text</name><description>a<!-- c -->b</description>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
          <Placemark><name>entities &amp; &amp;eacute;</name><Point><coordinates> 1,2,3 </coordinates></Point></Placemark>
          <Placemark><name>no geometry</name></Placemark>
          <Placemark><name/><LineString><coordinates></coordinates></LineString></Placemark>
          <Placemark><Polygon><innerBoundaryIs>
            <LinearRing><coordinates>0,0 1,0 1,1 0,0</coordinates></LinearRing>
          </innerBoundaryIs></Polygon></Placemark>
          <Placemark><Polygon>
            <outerBoundaryIs><LinearRing><coordinates>0,0 2,0 2,2 0,0</coordinates></LinearRing></outerBoundaryIs>
            <innerBoundaryIs><LinearRing><coordinates></coordinates></LinearRing></innerBoundaryIs>
          </Polygon></Placemark>
          <Placemark><MultiGeometry>
            <Point><coordinates>0,0</coordinates></Point>
            <MultiGeometry><LineString><coordinates>0,0 1,1</coordinates></LineString></MultiGeometry>
          </MultiGeometry></Placemark>
          <Placemark><MultiGeometry></MultiGeometry></Placemark>
          <Placemark><gx:Track><when>2010-05-28T02:02:09Z</when><gx:coord>1 2</gx:coord></gx:Track></Placemark>
          <Placemark><gx:Track></gx:Track></Placemark>
          <Placemark>
            <name>first</name><name>second</name>
            <Point><coordinates>5,5</coordinates></Point><Point><coordinates>6,6</coordinates></Point>
          </Placemark>
          <Placemark><Model><Location><longitude>1</longitude><latitude>2</latitude></Location></Model></Placemark>
          <Folder><Placemark><name>deep</name><Point><coordinates>7,8</coordinates></Point></Placemark></Folder>
        </Folder>
        <Folder>
          <name>Other</name>
          <Placemark><name>other</name><Point><coordinates>9,9</coordinates></Point></Placemark>
        </Folder>
      </Document>
    </kml>
    """
    edge_lazy = parse(LazyKMLFile, edge_kml)
    @test length(TB._placemark_iterator(edge_lazy, 1)) == 13
    for (file, k) in ((read(eg, LazyKMLFile), nothing), (multi_lazy, 1), (multi_lazy, 2),
                      (edge_lazy, 1), (edge_lazy, 2))
        it = TB._placemark_iterator(file, k)
        @test it isa TB.CursorPlacemarkIterator
        reference = TB.EagerLazyPlacemarkIterator(FastKML.Layers.select_layer(file, k))
        @test isequal(collect(it), collect(reference))
    end
end

@testset "Validation" begin
    V = FastKML.Validation

    # ── validate_coordinates(::Coord{2,3}) ──
    @test V.validate_coordinates(SVector(0.0, 0.0))         == (true, "")
    @test V.validate_coordinates(SVector(0.0, 0.0, 100.0))  == (true, "")

    ok_lon, msg_lon = V.validate_coordinates(SVector(200.0, 0.0))
    @test !ok_lon
    @test occursin("Longitude", msg_lon)

    ok_lat, msg_lat = V.validate_coordinates(SVector(0.0, 100.0))
    @test !ok_lat
    @test occursin("Latitude", msg_lat)

    # extreme altitude warns but the result is still (true, "")
    extreme = (@test_logs (:warn, r"Altitude") V.validate_coordinates(SVector(0.0, 0.0, 100_000.0)))
    @test extreme == (true, "")

    # ── validate_coordinates(::Vector) ──
    @test V.validate_coordinates([SVector(0.0, 0.0), SVector(1.0, 1.0)]) == (true, "")
    ok_vec, msg_vec = V.validate_coordinates([SVector(0.0, 0.0), SVector(200.0, 0.0)])
    @test !ok_vec
    @test occursin("Coordinate 2", msg_vec)

    # ── validate_geometry(::Point) ──
    @test V.validate_geometry(FastKML.Point(coordinates = SVector(0.0, 0.0)))[1]
    @test !V.validate_geometry(FastKML.Point(coordinates = nothing))[1]

    # ── validate_geometry(::LineString) ──
    valid_ls = FastKML.LineString(coordinates = [SVector(0.0, 0.0), SVector(1.0, 1.0)])
    @test V.validate_geometry(valid_ls)[1]
    @test !V.validate_geometry(FastKML.LineString(coordinates = nothing))[1]
    @test !V.validate_geometry(FastKML.LineString(coordinates = [SVector(0.0, 0.0)]))[1]

    # ── validate_geometry(::LinearRing) ──
    valid_ring = FastKML.LinearRing(coordinates = [
        SVector(0.0, 0.0), SVector(1.0, 0.0), SVector(1.0, 1.0), SVector(0.0, 0.0),
    ])
    @test V.validate_geometry(valid_ring)[1]
    @test !V.validate_geometry(FastKML.LinearRing(coordinates = nothing))[1]
    @test !V.validate_geometry(FastKML.LinearRing(coordinates = [SVector(0.0, 0.0)]))[1]

    unclosed = FastKML.LinearRing(coordinates = [
        SVector(0.0, 0.0), SVector(1.0, 0.0), SVector(1.0, 1.0), SVector(0.5, 0.5),
    ])
    ok_uc, msg_uc = V.validate_geometry(unclosed)
    @test !ok_uc
    @test occursin("not closed", msg_uc)

    # ── validate_geometry(::Polygon) ──
    # Outer-boundary presence is enforced at the type level
    # (`Polygon.outerBoundaryIs::LinearRing`, no `Nothing` in the union),
    # so validation only needs to walk the rings themselves. Test a
    # well-formed polygon, plus one with a malformed inner boundary.
    @test V.validate_geometry(FastKML.Polygon(outerBoundaryIs = valid_ring))[1]
    bad_poly = FastKML.Polygon(outerBoundaryIs = valid_ring, innerBoundaryIs = [unclosed])
    ok_bp, msg_bp = V.validate_geometry(bad_poly)
    @test !ok_bp
    @test occursin("Inner boundary", msg_bp)

    # ── validate_geometry(::MultiGeometry) ──
    @test V.validate_geometry(
        FastKML.MultiGeometry(Geometries = [FastKML.Point(coordinates = SVector(0.0, 0.0))]),
    )[1]
    @test !V.validate_geometry(FastKML.MultiGeometry(Geometries = nothing))[1]
    @test !V.validate_geometry(FastKML.MultiGeometry(Geometries = FastKML.Geometry[]))[1]

    # ── validate_document_structure(::Document) ──
    valid_doc = FastKML.Document(Features = [
        FastKML.Placemark(name = "P", Geometry = FastKML.Point(coordinates = SVector(0.0, 0.0))),
    ])
    ok_doc, issues_doc = V.validate_document_structure(valid_doc)
    @test ok_doc
    @test isempty(issues_doc)

    bad_doc = FastKML.Document(Features = [
        FastKML.Placemark(name = "Bad", Geometry = FastKML.Point(coordinates = nothing)),
    ])
    ok_bd, issues_bd = V.validate_document_structure(bad_doc)
    @test !ok_bd
    @test !isempty(issues_bd)

    empty_doc = FastKML.Document(Features = nothing)
    ok_ed, issues_ed = V.validate_document_structure(empty_doc)
    @test !ok_ed
    # Note: `contains(needle)` is the curry that matches `s -> contains(s, needle)`
    # — what we want here. `occursin(needle)` is `Base.Fix2(occursin, needle)`,
    # i.e. `s -> occursin(s, needle)`, which checks whether the issue string is
    # a substring of `needle`, not the other way around. Using `contains` keeps
    # the assertions readable.
    @test any(contains("no features"), issues_ed)

    # Nested Document warning
    nested_doc = FastKML.Document(Features = [FastKML.Document(Features = nothing)])
    ok_nd, issues_nd = V.validate_document_structure(nested_doc)
    @test !ok_nd
    @test any(contains("Nested Document"), issues_nd)

    # ── validate_document_structure(::Folder) ──
    valid_folder = FastKML.Folder(Features = [
        FastKML.Placemark(name = "P", Geometry = FastKML.Point(coordinates = SVector(0.0, 0.0))),
    ])
    @test V.validate_document_structure(valid_folder)[1]

    empty_folder = FastKML.Folder(Features = nothing)
    @test !V.validate_document_structure(empty_folder)[1]
end

@testset "ISO 8601 time parsing" begin
    parse_iso = FastKML.TimeParsing.parse_iso8601

    # ── Date forms ──
    @test parse_iso("2024-04-29") == Date(2024, 4, 29)        # extended
    @test parse_iso("20240429")   == Date(2024, 4, 29)        # basic

    # ── DateTime without TZ ──
    @test parse_iso("2024-04-29T15:30:00") == DateTime(2024, 4, 29, 15, 30, 0)
    @test parse_iso("20240429T153000")     == DateTime(2024, 4, 29, 15, 30, 0)

    # ── DateTime with TZ → ZonedDateTime ──
    @test parse_iso("2024-04-29T15:30:00Z")      isa ZonedDateTime
    @test parse_iso("2024-04-29T15:30:00+01:00") isa ZonedDateTime
    @test parse_iso("20240429T153000Z")          isa ZonedDateTime

    # ── Week date / Ordinal date ──
    @test parse_iso("2024-W17-1") isa Date
    @test parse_iso("2024-119")   isa Date

    # ── Invalid strings round-trip as the original String, with a warning ──
    @test (@test_logs (:warn,) parse_iso("ab")) isa String
    @test (@test_logs (:warn,) parse_iso("not a date at all")) isa String

    # ── warn=false suppresses warnings ──
    @test parse_iso("definitely not iso"; warn = false) == "definitely not iso"

    # ── is_valid_iso8601 ──
    @test FastKML.TimeParsing.is_valid_iso8601("2024-04-29")
    @test !FastKML.TimeParsing.is_valid_iso8601("not iso")

    # ── Integration: a synthetic KML with <TimeStamp> exercises the
    #    field_conversion → time_parsing call chain on the eager path ──
    timed_kml = """<?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>Stamped</name>
          <TimeStamp><when>2024-04-29T12:00:00Z</when></TimeStamp>
          <Point><coordinates>0,0,0</coordinates></Point>
        </Placemark>
        <Placemark>
          <name>Spanned</name>
          <TimeSpan>
            <begin>2024-01-01</begin>
            <end>2024-12-31</end>
          </TimeSpan>
          <Point><coordinates>1,1,0</coordinates></Point>
        </Placemark>
      </Document>
    </kml>
    """
    file = parse(KMLFile, timed_kml)
    pms = FastKML.Utils.find_placemarks(file)
    @test length(pms) == 2
    # The TimePrimitive field should be populated and carry the parsed
    # `when` / `begin` / `end` (not the original strings).
    @test pms[1].TimePrimitive !== nothing
    @test pms[2].TimePrimitive !== nothing
end

@testset "ZipArchives extension (KMZ)" begin
    eg = joinpath(@__DIR__, "example.kml")
    eg_bytes = read(eg)

    mktempdir() do dir
        # Standard case: doc.kml at the root of the archive — first
        # branch of `_find_kml_entry_in_kmz`'s prioritization.
        kmz_path = joinpath(dir, "test.kmz")
        ZipWriter(kmz_path) do zw
            zip_newfile(zw, "doc.kml")
            write(zw, eg_bytes)
        end

        # Eager KMZ → KMLFile (drives `_read_file_from_path(::KMZ_…)`)
        kml_eager = read(kmz_path, KMLFile)
        @test kml_eager isa KMLFile
        @test FastKML.Utils.count_features(kml_eager)[:Placemark] == 3

        # Lazy KMZ → LazyKMLFile (drives `_read_lazy_file_from_path(::KMZ_…)`)
        kml_lazy = read(kmz_path, LazyKMLFile)
        @test kml_lazy isa LazyKMLFile

        # End-to-end: DataFrame on a .kmz path goes through the lazy
        # branch of the extension and Tables.rows(PlacemarkTable).
        df = DataFrame(kmz_path)
        @test nrow(df) == 3
        @test names(df) == ["name", "description", "geometry"]
    end

    # Fallback case: KML entry under a subdirectory rather than at root.
    # Exercises a different branch of `_find_kml_entry_in_kmz`.
    mktempdir() do dir
        kmz_path = joinpath(dir, "nested.kmz")
        ZipWriter(kmz_path) do zw
            zip_newfile(zw, "data/inner.kml")
            write(zw, eg_bytes)
        end
        @test read(kmz_path, KMLFile) isa KMLFile
    end
end

@testset "DataFrames extension" begin
    eg = joinpath(@__DIR__, "example.kml")

    # Path with default lazy=true → goes through the LazyKMLFile branch
    df_lazy_default = DataFrame(eg)
    @test df_lazy_default isa DataFrame
    @test names(df_lazy_default) == ["name", "description", "geometry"]
    @test nrow(df_lazy_default) == 3

    # Path with lazy=false → exercises the eager KMLFile branch
    df_eager_path = DataFrame(eg; lazy = false)
    @test df_eager_path isa DataFrame
    @test nrow(df_eager_path) == 3

    # KMLFile / LazyKMLFile object overload (skips the path branch entirely)
    file_eager = read(eg, KMLFile)
    file_lazy  = read(eg, LazyKMLFile)
    @test DataFrame(file_eager) isa DataFrame
    @test DataFrame(file_lazy)  isa DataFrame

    # `layer` and `simplify_single_parts` keywords flow through to PlacemarkTable
    @test nrow(DataFrame(eg; layer = 1)) == 3
    @test DataFrame(eg; simplify_single_parts = true) isa DataFrame
end

@testset "REPL extension (layer menu)" begin
    # Loading REPL, as every REPL session does, loads the interactive layer menu.
    @test Base.get_extension(FastKML, :FastKMLREPLExt) !== nothing
    @test hasmethod(FastKML.Layers._choose_layer_interactively, Tuple{Vector{String}})

    # Loading FastKML alone loads neither REPL nor InteractiveUtils. Where the system image
    # already holds them (Julia 1.10), they are loaded before and after alike.
    code = """
        ids = (Base.PkgId(Base.UUID("3fa0cd96-eef1-5676-8a61-b3b8758bbffb"), "REPL"),
               Base.PkgId(Base.UUID("b77e0a4c-d291-57a0-90e8-8db25a27a240"), "InteractiveUtils"))
        before = map(id -> haskey(Base.loaded_modules, id), ids)
        using FastKML
        print(map(id -> haskey(Base.loaded_modules, id), ids) == before)
        """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
    @test read(cmd, String) == "true"

    # A REPL session does not always expose REPL to package extensions (Julia 1.13 does not),
    # so `select_layer` loads REPL itself when it needs the menu, which brings the extension.
    code = """
        using FastKML
        print(FastKML.Layers._layer_menu_available(["A", "B"]), " ",
              Base.get_extension(FastKML, :FastKMLREPLExt) !== nothing)
        """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`
    @test read(cmd, String) == "true true"
end

@testset "layer=:all single-pass extraction" begin
    # Multi-layer fixture with a deliberate duplicate layer name (`Layer A`
    # appears twice). The dedicated layer_idx column distinguishes them so
    # downstream consumers don't need to invent fallback identifiers.
    kml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Folder>
          <name>Layer A</name>
          <Placemark><name>p1</name><Point><coordinates>1.0,2.0</coordinates></Point></Placemark>
          <Placemark><name>p2</name><Point><coordinates>3.0,4.0</coordinates></Point></Placemark>
        </Folder>
        <Folder>
          <name>Layer B</name>
          <Placemark><name>p3</name><Point><coordinates>5.0,6.0</coordinates></Point></Placemark>
        </Folder>
        <Folder>
          <name>Layer A</name>
          <Placemark><name>dup1</name><Point><coordinates>7.0,8.0</coordinates></Point></Placemark>
        </Folder>
      </Document>
    </kml>
    """

    # ── Lazy path ──
    file_lazy = parse(LazyKMLFile, kml)
    df_lazy = DataFrame(file_lazy; layer = :all)
    @test names(df_lazy) == ["layer_idx", "layer_name", "name", "description", "geometry"]
    @test nrow(df_lazy) == 4
    @test df_lazy.layer_idx  == [1, 1, 2, 3]
    @test df_lazy.layer_name == ["Layer A", "Layer A", "Layer B", "Layer A"]
    @test df_lazy.name       == ["p1", "p2", "p3", "dup1"]
    # Duplicate-name layers stay distinguishable via layer_idx
    @test count(==("Layer A"), df_lazy.layer_name) == 3
    @test Set(df_lazy.layer_idx[df_lazy.layer_name .== "Layer A"]) == Set([1, 3])
    # Each layer is read with the cursor walk, whose rows are those of the LazyNode walk.
    TB = FastKML.TablesBridge
    reference = DataFrame([(; layer_idx = idx, layer_name = lname, pl...)
                           for (idx, lname, src) in TB.get_layer_info(file_lazy)
                           for pl in TB.EagerLazyPlacemarkIterator(src)])
    @test isequal(df_lazy, reference)

    # ── Eager path ──
    file_eager = parse(KMLFile, kml)
    df_eager = DataFrame(file_eager; layer = :all)
    @test nrow(df_eager) == 4
    @test df_eager.layer_idx  == [1, 1, 2, 3]
    @test df_eager.layer_name == ["Layer A", "Layer A", "Layer B", "Layer A"]
    @test df_eager.name       == ["p1", "p2", "p3", "dup1"]

    # ── Tables.jl schema honors :all ──
    pt = FastKML.PlacemarkTable(file_lazy; layer = :all)
    sch = Tables.schema(pt)
    @test sch.names == (:layer_idx, :layer_name, :name, :description, :geometry)
    @test sch.types == (Int, String, String, String, Union{Missing,FastKML.Geometry})

    # ── Symbol validation ──
    # The constructor should reject any Symbol other than :all.
    @test_throws ErrorException FastKML.PlacemarkTable(file_lazy; layer = :first)
    @test_throws ErrorException FastKML.PlacemarkTable(file_lazy; layer = :all_layers)

    # ── Existing single-layer modes still keep the 3-column schema ──
    pt_single = FastKML.PlacemarkTable(file_lazy; layer = 1)
    sch_single = Tables.schema(pt_single)
    @test sch_single.names == (:name, :description, :geometry)
    @test nrow(DataFrame(file_lazy; layer = 1)) == 2  # Layer A (idx 1) has 2 placemarks
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

    # The table holds the 2125 names that the HTML standard's list writes with a semicolon
    # (the standard declares the list static). The historical forms without one (`&amp`,
    # `&para`, …) must neither add a name one character short nor overwrite a real name.
    @test length(FastKML.HtmlEntities.NAMED_HTML_ENTITIES) == 2125
    @test decode("&l; &am; &nbs; &AEli;") == "&l; &am; &nbs; &AEli;"
    @test decode("&par; &para;") == "\u2225 \u00b6"
    @test decode("&ecir; &ocir; &ord;") == "\u2256 \u229a \u2a5d"

    # A name can stand for two code points
    @test decode("&NotEqualTilde;") == "\u2242\u0338"

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

@testset "gx:Track parsing" begin
    path = joinpath(@__DIR__, "gx_Track_example.kml")

    # ── Eager path (via KMLFile + struct hierarchy) ──
    file = read(path, KMLFile)
    @test file isa KMLFile
    pms = FastKML.Utils.find_placemarks(file)
    @test length(pms) == 1
    pm = pms[1]
    @test pm.name == "2010-05-28T01:16:35.000Z"
    @test pm.Geometry isa FastKML.gx_Track

    track = pm.Geometry
    # Each <when> / <gx:coord> in the source contributes one entry. Without
    # the `assign_field!` accumulation fix, repeated <gx:coord> elements would
    # overwrite each other and the field would only retain the last one.
    @test length(track.when) == 7
    @test length(track.gx_coord) == 7
    @test track.gx_coord[1]   ≈ SVector(-122.207881, 37.371915, 156.0)
    @test track.gx_coord[end] ≈ SVector(-122.203207, 37.374857, 140.199997)
    # ExtendedData must land on `gx_Track.ExtendedData`, NOT be misrouted to
    # `gx_coord` (regression for the `assign_complex_object!` Union-vector
    # eltype-widening bug — see field_conversion.jl).
    @test track.ExtendedData !== nothing

    # ── Schema with gx:SimpleArrayField declarations ──
    doc = file[1]
    @test doc isa FastKML.Document
    @test doc.Schemas !== nothing && length(doc.Schemas) == 1
    schema = doc.Schemas[1]
    @test schema.id == "schema"
    # OGC <SimpleField>s are absent in this file; only Google's gx variants.
    @test schema.SimpleFields === nothing
    @test schema.gx_SimpleArrayFields !== nothing
    @test length(schema.gx_SimpleArrayFields) == 3
    @test Set((f.name, f.type, f.displayName) for f in schema.gx_SimpleArrayFields) == Set([
        ("heartrate", "int",   "Heart Rate"),
        ("cadence",   "int",   "Cadence"),
        ("power",     "float", "Power"),
    ])
    # name and id are the two optional attributes of <Schema>. An id is an XML ID: never empty.
    @test schema.name === nothing
    named = FastKML.object(XML.parse(
        """<Schema name="track" id="trackSchema"><SimpleField type="int" name="hr"/></Schema>""", XML.Node)[1])
    @test (named.name, named.id) == ("track", "trackSchema")
    bare = FastKML.object(XML.parse("""<Schema><SimpleField type="int" name="hr"/></Schema>""", XML.Node)[1])
    @test bare.id === nothing
    @test occursin("<Schema>", sprint(FastKML.write, bare))

    # ── ExtendedData → SchemaData → gx:SimpleArrayData with one <gx:value> per Track point ──
    @test track.ExtendedData.children !== nothing
    @test length(track.ExtendedData.children) == 1
    sd = track.ExtendedData.children[1]
    @test sd isa FastKML.SchemaData
    @test sd.schemaUrl == "#schema"
    @test sd.gx_SimpleArrayDatas !== nothing
    @test length(sd.gx_SimpleArrayDatas) == 3
    by_name = Dict(d.name => d.gx_value for d in sd.gx_SimpleArrayDatas)
    @test by_name["cadence"]   == ["86", "103", "108", "113", "113", "113", "113"]
    @test by_name["heartrate"] == ["181", "177", "175", "173", "173", "173", "173"]
    @test by_name["power"]     == ["327.0", "177.0", "179.0", "162.0", "166.0", "177.0", "183.0"]

    # ── One <gx:angles> per Track point, like <when> and <gx:coord> ──
    angles_pm = FastKML.object(XML.parse("""
        <Placemark><gx:Track>
          <when>2010-05-28T02:02:09Z</when><when>2010-05-28T02:02:35Z</when>
          <gx:coord>1 2 3</gx:coord><gx:coord>4 5 6</gx:coord>
          <gx:angles>45.54 66.2 4.13</gx:angles><gx:angles>46.1 66 4</gx:angles>
        </gx:Track></Placemark>""", XML.Node)[1])
    @test angles_pm.Geometry.gx_angles == ["45.54 66.2 4.13", "46.1 66 4"]

    # ── Lazy path (via LazyKMLFile) ──
    lazy = read(path, LazyKMLFile)
    @test lazy isa LazyKMLFile
    @test get_num_layers(lazy) == 1
    @test get_layer_names(lazy) == ["Tracks"]

    # The lazy table recognises gx:Track and returns a populated
    # `gx_Track` (when + gx_coord). It leaves auxiliary fields
    # (ExtendedData, Model, Icon, gx_angles) at default — read as `KMLFile`
    # if you need those.
    df = DataFrame(path)
    @test nrow(df) == 1
    @test df.name[1] == "2010-05-28T01:16:35.000Z"
    @test df.geometry[1] isa FastKML.gx_Track
    lazy_track = df.geometry[1]
    @test length(lazy_track.when)     == 7
    @test length(lazy_track.gx_coord) == 7
    @test lazy_track.gx_coord[1]   ≈ SVector(-122.207881, 37.371915, 156.0)
    @test lazy_track.gx_coord[end] ≈ SVector(-122.203207, 37.374857, 140.199997)
    @test lazy_track.when[1] isa TimeZones.ZonedDateTime
    @test lazy_track.ExtendedData === nothing  # documented lazy-path limitation
end

@testset "gx:TimeStamp / gx:TimeSpan in AbstractView" begin
    # Google extension: <gx:TimeStamp> and <gx:TimeSpan> are children of
    # <Camera> / <LookAt>, attaching a time component to a view (something
    # OGC 2.2 doesn't model directly). They share the field shape of the
    # standard TimePrimitive types and ride the existing
    # `Camera.TimePrimitive` / `LookAt.TimePrimitive` field via abstract-type
    # dispatch in `assign_complex_object!`.

    # ── Existing fixture: gx_Track_example.kml has a <gx:TimeSpan> in <LookAt> ──
    # Before Phase 4 this fired the "Unhandled Tag: gx:TimeSpan" warning and
    # the LookAt's TimePrimitive stayed `nothing`. Now it parses cleanly.
    file = read(joinpath(@__DIR__, "gx_Track_example.kml"), KMLFile)
    function find_first_lookat(node)
        function walk(o)
            o isa FastKML.LookAt && return o
            for f in fieldnames(typeof(o))
                v = getfield(o, f)
                if v isa FastKML.KMLElement
                    r = walk(v); r !== nothing && return r
                elseif v isa AbstractVector
                    for x in v
                        if x isa FastKML.KMLElement
                            r = walk(x); r !== nothing && return r
                        end
                    end
                end
            end
            return nothing
        end
        for c in node.children
            if c isa FastKML.KMLElement
                r = walk(c); r !== nothing && return r
            end
        end
        return nothing
    end

    la = find_first_lookat(file)
    @test la !== nothing
    @test la.TimePrimitive isa FastKML.gx_TimeSpan
    span = la.TimePrimitive
    @test span.begin_ isa TimeZones.ZonedDateTime
    @test span.end_   isa TimeZones.ZonedDateTime
    @test span.begin_ < span.end_

    # ── Synthetic: <gx:TimeStamp> in <Camera> ──
    kml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2"
         xmlns:gx="http://www.google.com/kml/ext/2.2">
      <Document>
        <Placemark>
          <name>p1</name>
          <Camera>
            <gx:TimeStamp>
              <when>2008-06-15T12:30:00Z</when>
            </gx:TimeStamp>
            <longitude>10.0</longitude>
            <latitude>20.0</latitude>
            <altitude>500.0</altitude>
          </Camera>
          <Point><coordinates>10.0,20.0</coordinates></Point>
        </Placemark>
      </Document>
    </kml>
    """
    file2 = parse(KMLFile, kml)
    pm = FastKML.Utils.find_placemarks(file2)[1]
    @test pm.AbstractView isa FastKML.Camera
    @test pm.AbstractView.TimePrimitive isa FastKML.gx_TimeStamp
    @test pm.AbstractView.TimePrimitive.when isa TimeZones.ZonedDateTime

    # Empty constructor (also covered by the Empty Constructors testset
    # via all_concrete_subtypes(KMLElement), spot-check explicitly here).
    @test FastKML.gx_TimeStamp().when === nothing
    @test FastKML.gx_TimeSpan().begin_ === nothing
    @test FastKML.gx_TimeSpan().end_ === nothing
end

@testset "ScreenOverlay positioning" begin
    # overlayXY, screenXY, rotationXY and size all have the type `hotSpot`: each element must
    # be read into the field its tag names, whatever their order.
    kml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <ScreenOverlay>
          <name>legend</name>
          <overlayXY x="0" y="1" xunits="fraction" yunits="fraction"/>
          <screenXY x="10" y="20" xunits="pixels" yunits="insetPixels"/>
          <rotationXY x="0.5" y="0.25" xunits="fraction" yunits="fraction"/>
          <size x="100" y="0.2" xunits="pixels" yunits="fraction"/>
        </ScreenOverlay>
        <ScreenOverlay>
          <size x="3" y="4" xunits="pixels" yunits="pixels"/>
          <overlayXY x="1" y="2" xunits="pixels" yunits="pixels"/>
        </ScreenOverlay>
      </Document>
    </kml>
    """
    xy(h) = h === nothing ? nothing : (h.x, h.y, string(h.xunits), string(h.yunits))
    for file in (parse(KMLFile, kml), KMLFile(parse(LazyKMLFile, kml)))
        legend, other = file.children[1].Features
        @test xy(legend.overlayXY)  == (0.0, 1.0, "fraction", "fraction")
        @test xy(legend.screenXY)   == (10.0, 20.0, "pixels", "insetPixels")
        @test xy(legend.rotationXY) == (0.5, 0.25, "fraction", "fraction")
        @test xy(legend.size)       == (100.0, 0.2, "pixels", "fraction")
        @test xy(other.size)        == (3.0, 4.0, "pixels", "pixels")
        @test xy(other.overlayXY)   == (1.0, 2.0, "pixels", "pixels")
        @test other.screenXY === nothing
        @test other.rotationXY === nothing
    end
end

@testset "NetworkLinkControl modeling" begin
    # OGC 2.2 §12.2: <NetworkLinkControl> is a top-level <kml> child carrying
    # session metadata for a NetworkLink. All fields are optional; we exercise
    # all of them here, including the <linkSnippet> alias (Snippet type re-used
    # under a tag distinct from <Snippet>) and the abstract <AbstractView>
    # routing (LookAt picked up via abstract type dispatch).
    kml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <NetworkLinkControl>
        <minRefreshPeriod>0.5</minRefreshPeriod>
        <maxSessionLength>3600</maxSessionLength>
        <cookie>session=abc</cookie>
        <message>System maintenance Friday 14:00 UTC</message>
        <linkName>Operational Layer</linkName>
        <linkDescription>Live data feed</linkDescription>
        <linkSnippet maxLines="3">Snippet text content</linkSnippet>
        <expires>2026-12-31T23:59:59Z</expires>
        <LookAt>
          <longitude>-122.4</longitude>
          <latitude>37.78</latitude>
          <altitude>1000</altitude>
        </LookAt>
      </NetworkLinkControl>
      <Document>
        <name>doc</name>
      </Document>
    </kml>
    """

    # Eager parse: no warning, both children materialized
    file = @test_logs min_level = Logging.Warn parse(KMLFile, kml)
    @test length(file.children) == 2
    @test file.children[1] isa FastKML.NetworkLinkControl
    @test file.children[2] isa FastKML.Document

    nlc = file.children[1]
    @test nlc.minRefreshPeriod == 0.5
    @test nlc.maxSessionLength == 3600.0
    @test nlc.cookie == "session=abc"
    @test nlc.message == "System maintenance Friday 14:00 UTC"
    @test nlc.linkName == "Operational Layer"
    @test nlc.linkDescription == "Live data feed"
    @test nlc.expires == "2026-12-31T23:59:59Z"
    @test nlc.Update === nothing  # not present in fixture

    # linkSnippet is aliased onto the Snippet type; both content and the
    # maxLines attribute survive.
    @test nlc.linkSnippet isa FastKML.Snippet
    @test nlc.linkSnippet.content == "Snippet text content"
    @test nlc.linkSnippet.maxLines == 3

    # AbstractView dispatch: <LookAt> reached the abstract field.
    @test nlc.AbstractView isa FastKML.LookAt
    @test nlc.AbstractView.longitude == -122.4
    @test nlc.AbstractView.latitude == 37.78
    @test nlc.AbstractView.altitude == 1000.0

    # Empty constructor still works (covered by the Empty Constructors testset
    # via all_concrete_subtypes(KMLElement), but spot-check here too)
    empty_nlc = FastKML.NetworkLinkControl()
    @test empty_nlc.minRefreshPeriod === nothing
    @test empty_nlc.message === nothing
    @test empty_nlc.AbstractView === nothing
end

@testset "Metadata (deprecated OGC container)" begin
    # OGC 2.2 §6.7: <Metadata> is deprecated and contains <any
    # processContents="lax">. Phase 5 models it as a Feature child whose
    # `children` field preserves raw XML.AbstractXMLNode references —
    # opaque content not parsed by add_element!, so we don't emit
    # spurious "Unhandled tag" warnings for the legacy payload.
    kml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>p</name>
          <Metadata>
            <foo>123</foo>
            <bar>hello</bar>
          </Metadata>
          <Point><coordinates>1.0,2.0</coordinates></Point>
        </Placemark>
      </Document>
    </kml>
    """

    # No warning expected — Metadata's children must NOT trigger
    # "Unhandled tag" emissions in add_element!.
    file = @test_logs min_level = Logging.Warn parse(KMLFile, kml)
    pm = FastKML.Utils.find_placemarks(file)[1]
    @test pm.Metadata isa FastKML.Metadata
    @test length(pm.Metadata.children) == 2
    # Raw XML.Node references — caller can introspect via XML.tag.
    @test XML.tag(pm.Metadata.children[1]) == "foo"
    @test XML.tag(pm.Metadata.children[2]) == "bar"

    # Empty constructor sanity check
    @test isempty(FastKML.Metadata().children)
end

@testset "gx:ViewerOptions / gx:option (Google extension)" begin
    # Google ext: <gx:ViewerOptions> wraps zero+ <gx:option> children
    # inside <Camera> / <LookAt>. Each option carries name + enabled
    # attributes (e.g. streetview, historicalimagery, sunlight).
    kml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2"
         xmlns:gx="http://www.google.com/kml/ext/2.2">
      <Document>
        <Placemark>
          <name>p</name>
          <Camera>
            <longitude>10.0</longitude>
            <latitude>20.0</latitude>
            <altitude>500.0</altitude>
            <gx:ViewerOptions>
              <gx:option name="streetview" enabled="true"/>
              <gx:option name="historicalimagery" enabled="false"/>
              <gx:option name="sunlight" enabled="true"/>
            </gx:ViewerOptions>
          </Camera>
          <Point><coordinates>10.0,20.0</coordinates></Point>
        </Placemark>
      </Document>
    </kml>
    """

    file = @test_logs min_level = Logging.Warn parse(KMLFile, kml)
    pm = FastKML.Utils.find_placemarks(file)[1]
    cam = pm.AbstractView
    @test cam isa FastKML.Camera
    @test cam.gx_ViewerOptions isa FastKML.gx_ViewerOptions
    vo = cam.gx_ViewerOptions
    @test length(vo.gx_options) == 3
    @test vo.gx_options[1].name == "streetview"
    @test vo.gx_options[1].enabled === true
    @test vo.gx_options[2].name == "historicalimagery"
    @test vo.gx_options[2].enabled === false
    @test vo.gx_options[3].name == "sunlight"
    @test vo.gx_options[3].enabled === true

    # Empty constructors
    @test FastKML.gx_ViewerOptions().gx_options === nothing
    @test FastKML.gx_option().name === nothing
    @test FastKML.gx_option().enabled === nothing
end

@testset "Styles" begin
    # <listItemType> takes the values of its enumeration.
    ls = FastKML.object(XML.parse(
        "<ListStyle><listItemType>checkHideChildren</listItemType></ListStyle>", XML.Node)[1])
    @test ls.listItemType == FastKML.Enums.listItemType("checkHideChildren")
end

@testset "Atom elements" begin
    # The children of <atom:author> are Atom elements, read like the other prefixed elements.
    doc = FastKML.object(XML.parse("""
        <Document><atom:author>
          <atom:name>A. Author</atom:name><atom:uri>https://example.org/</atom:uri><atom:email>a@example.org</atom:email>
        </atom:author></Document>""", XML.Node)[1])
    author = doc.atom_author
    @test (author.atom_name, author.atom_uri, author.atom_email) ==
          ("A. Author", "https://example.org/", "a@example.org")
end

@testset "Unmodeled top-level tags are skipped, not fatal" begin
    # Regression: real-world feeds (e.g. USGS earthquake animated KML) put
    # unmodeled top-level KML elements alongside the Document
    # (`<NetworkLinkControl>` in OGC 2.2, future Google extensions, etc.).
    # `parse_kmlfile` used to call
    # `push!(::Vector{Union{XML.AbstractXMLNode,KMLElement}}, ::Nothing)`
    # on the value returned by `object()` for these tags, raising a
    # MethodError. The fix filters anything that isn't a KMLElement so the
    # rest of the file remains usable.
    kml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <UnhandledStructuredTag>
        <message>looks like a NetworkLinkControl</message>
      </UnhandledStructuredTag>
      <UnhandledLeafTag>plain text payload</UnhandledLeafTag>
      <Document>
        <name>survives the unknown siblings</name>
      </Document>
    </kml>
    """

    # The "Unhandled Tag" warning from `_object_slow` must fire for the
    # structured tag — silent data loss would be worse than a crash.
    # (The simple-leaf path does not warn; that's a separate concern.)
    file = @test_logs (:warn, r"Unhandled Tag.*UnhandledStructuredTag") match_mode = :any begin
        parse(KMLFile, kml)
    end

    # Both unknown tags filtered; only the Document survives intact.
    @test length(file.children) == 1
    @test file.children[1] isa FastKML.Document
    @test file.children[1].name == "survives the unknown siblings"
end

# ── Network-gated integration tests vs ArchGDAL ─────────────────────────────
# Set `FASTKML_INTEGRATION=true` to run. Pulls KML/KMZ files from the web,
# parses with both libraries, and asserts the resulting DataFrames agree.
# Adds `ArchGDAL`, `WellKnownGeometry`, `URIs`, and `Scratch` as test deps.
if get(ENV, "FASTKML_INTEGRATION", "false") == "true"
    include("integration_archgdal_test.jl")
end