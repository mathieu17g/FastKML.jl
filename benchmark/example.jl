# Download and read public KML sample
using KML, DataFrames, Downloads

# Google's KML samples - specify extension for proper detection
url = "https://developers.google.com/kml/documentation/KML_Samples.kml"
kml_file = Downloads.download(url, tempname() * ".kml")
kml = read(kml_file, KMLFile)
display(kml)

# List available layers
list_layers(kml)

# Convert to DataFrame
df = DataFrame(kml)
display(df)

# Direct visualization with USGS earthquake data
using KML, GeoMakie, GLMakie, Downloads

# Download USGS earthquake KML (past 30 days, magnitude 2.5+)
url = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_month_depth_animated.kml"
earthquake_file = Downloads.download(url, tempname() * ".kml")

# Read and extract earthquake locations
df = DataFrame(earthquake_file; layer=1)

# Visualize on a map
fig = Figure(size=(1200, 800))
ax = GeoAxis(fig[1,1], title="Recent Earthquakes (M2.5+)")
lines!(ax, GeoMakie.coastlines())
for row in eachrow(df)
    !ismissing(row.geometry) && plot!(ax, row.geometry, color=:red, markersize=8)
end
display(fig)

# Process KMZ files efficiently with lazy loading
# USGS Kilauea volcano data
using ZipArchives
url = "https://pubs.usgs.gov/of/2007/1264/SteepestDescents_Kilauea1983_10m_cell7500.KMZ"
kmz_file = Downloads.download(url, tempname() * ".kmz")

# Use lazy loading for compressed files
lazy_kml = read(kmz_file, LazyKMLFile)
list_layers(lazy_kml)

# Extract data without loading entire file
df = DataFrame(lazy_kml; layer=1)
filter(row -> !ismissing(row.geometry), df) |> display

# Handle geometry type conflicts gracefully
using GeometryBasics  # Defines Point, LineString, etc.
using KML  # Warns about conflicts and suggests solutions
# Use KML.Point to disambiguate