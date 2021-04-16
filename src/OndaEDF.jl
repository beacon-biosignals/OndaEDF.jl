module OndaEDF

using Base.Iterators
using Dates, UUIDs
using Onda, EDF
using TimeSpans
using Tables
using Tables: rowmerge

include("standards.jl")

include("import_edf.jl")
export edf_to_onda_samples, edf_to_onda_annotations, store_edf_as_onda

include("export_edf.jl")
export onda_to_edf

end # module
