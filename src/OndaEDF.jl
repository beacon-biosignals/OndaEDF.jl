module OndaEDF

using Base.Iterators
using Dates, UUIDs
using Onda, EDF
using TimeSpans

include("standards.jl")

include("import_edf.jl")
export import_edf!

include("export_edf.jl")
#export export_edf

end # module
