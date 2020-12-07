using OndaEDF
using Documenter

makedocs(modules=[OndaEDF],
         sitename="OndaEDF",
         authors="Beacon Biosignals and other contributors",
         pages=["API Documentation" => "index.md"])

deploydocs(repo="github.com/beacon-biosignals/OndaEDF.jl.git")
