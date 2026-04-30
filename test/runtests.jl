using FastKML
using DataFrames
using Dates
using GeoInterface
using Tables
using Test
using TimeZones
using XML
using StaticArrays  # Add this import
using ZipArchives



@testset "Issue Coverage" begin
    # https://github.com/JuliaComputing/FastKML.jl/issues/8
    @test_warn "Unhandled Tag" read(joinpath(@__DIR__, "outside_spec.kml"), KMLFile)

    # https://github.com/JuliaComputing/FastKML.jl/issues/12
    @test read(joinpath(@__DIR__, "issue12.kml"), KMLFile) isa KMLFile
end

@testset "Empty Constructors" begin
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

    # ── Lazy path (via LazyKMLFile) ──
    lazy = read(path, LazyKMLFile)
    @test lazy isa LazyKMLFile
    @test get_num_layers(lazy) == 1
    @test get_layer_names(lazy) == ["Tracks"]

    # `parse_geometry_lazy` (tables.jl) currently only recognises
    # Point / LineString / Polygon / MultiGeometry tags as geometries, so
    # gx:Track returns `missing` on the lazy DataFrame path. The eager path
    # above is the way to access gx_Track data programmatically.
    df = DataFrame(path)
    @test nrow(df) == 1
    @test df.name[1] == "2010-05-28T01:16:35.000Z"
    @test ismissing(df.geometry[1])
end

# ── Network-gated integration tests vs ArchGDAL ─────────────────────────────
# Set `FASTKML_INTEGRATION=true` to run. Pulls KML/KMZ files from the web,
# parses with both libraries, and asserts the resulting DataFrames agree.
# Adds `ArchGDAL`, `WellKnownGeometry`, `URIs`, and `Scratch` as test deps.
if get(ENV, "FASTKML_INTEGRATION", "false") == "true"
    include("integration_archgdal_test.jl")
end