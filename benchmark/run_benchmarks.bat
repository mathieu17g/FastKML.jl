@echo off
REM Batch file to run benchmarks on both branches

echo ================================================================================
echo KML.jl Cross-Branch Benchmarks
echo ================================================================================

echo.
echo Benchmarking main branch...
git -C ..\dev\KML checkout main
set KML_BRANCH=main
julia --project=. -e "using Pkg; Pkg.resolve(); Pkg.instantiate(); Pkg.precompile()"
julia --project=. cross_branch_benchmark.jl

echo.
echo Benchmarking parsing_perf_enhancement branch...
git -C ..\dev\KML checkout parsing_perf_enhancement
set KML_BRANCH=parsing_perf_enhancement
julia --project=. -e "using Pkg; Pkg.resolve(); Pkg.instantiate(); Pkg.precompile()"
julia --project=. cross_branch_benchmark.jl

echo.
echo Benchmarks complete!
pause