module OndaEDF

using Base.Iterators
using Compat: @compat
using Dates, UUIDs
using Onda, EDF
using StatsBase
using TimeSpans
using Tables
using Tables: rowmerge

# can be dropped if we drop Onda<0.14
sample_type(x) = isdefined(Onda, :sample_type) ? Onda.sample_type(x) : x.sample_type

include("standards.jl")

include("import_edf.jl")
export edf_to_onda_samples, edf_to_onda_annotations, store_edf_as_onda
export extract_channels_by_label, edf_signals_to_samplesinfo

include("export_edf.jl")
export onda_to_edf

include("prettyprint_diagnostic_info.jl")

end # module
