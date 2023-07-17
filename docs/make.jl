using OndaEDF
using Documenter

makedocs(modules=[OndaEDF, OndaEDF.OndaEDFSchemas],
         sitename="OndaEDF",
         authors="Beacon Biosignals and other contributors",
         pages=["OndaEDF" => "index.md",
                "Converting from EDF" => "convert-to-onda.md",
                "API Documentation" => "api.md"])

deploydocs(repo="github.com/beacon-biosignals/OndaEDF.jl.git",
           push_preview=true)
