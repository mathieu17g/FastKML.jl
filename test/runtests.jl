using FastKML
using GeoInterface
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