using Documenter
using FastKML

makedocs(
    sitename = "FastKML.jl",
    modules  = [FastKML],
    format   = Documenter.HTML(prettyurls = get(ENV, "CI", "false") == "true"),
    pages    = [
        "Home"                  => "index.md",
        "Coordinate parsing"    => "coordinate_parsing.md",
        "Eager vs lazy parsing" => "eager_vs_lazy.md",
        "API reference"         => "api.md",
    ],
    checkdocs = :none,
    warnonly  = true,
)
