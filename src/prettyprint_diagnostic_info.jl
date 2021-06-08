function _print_result_value(f, si::SamplesInfo; indent=0, kwargs...)
    print(f, "$(repeat(' ', indent))SamplesInfo(")
    print(f, join([repr(getproperty(si, field)) for field in fieldnames(SamplesInfo)], ", "))
    print(f, ")")
end

function _print_result_value(f, p::Pair{A, Vector{B}}; indent=0, tab=4) where {A, B}
    _print_result_value(f, first(p); indent=indent, tab=tab)
    println(f, " => [")
    for x in last(p)
        _print_result_value(f, x; indent=indent+tab, tab=tab)
        println(f, ",")
    end
    print(f, "$(repeat(' ', indent))]")
end

function _print_result_value(f, v::Vector; indent=0, tab=4)
    println(f, "$(repeat(' ', indent))[")
    for x in v
        _print_result_value(f, x; indent=indent + tab, tab=tab)
        println(f, ",")
    end
    print(f, "$(repeat(' ', indent))]")
end

_print_result_value(f, e; indent=0, kwargs...) = print(f, "$(repeat(' ', indent))$(repr(e))")

function print_result(f, r, label; indent=0, tab=4)
    println(f, "$(repeat(' ', indent))($(repeat(' ', indent-1))# $label")
    for (field, value) in pairs(r)
        println(f, "$(repeat(' ', indent + tab))$field=")
        _print_result_value(f, value; indent=2 * tab + indent)
        println(f, ",")
    end
    print(f, "$(repeat(' ', indent)))")
end

function prettyprint_diagnostic_info(f::IO, results)
    println(f, "[")
    for (i, result) in enumerate(results)
        print_result(f, result, i; indent=4)
        println(f, ",")
    end
    print(f, "]")
end

_edf_headers(r) = vcat(map(last, r.header_map)..., r.unextracted_edf_headers)

_groupby(r) = Set((h.label, h.transducer_type, h.physical_dimension)
                 for h in _edf_headers(r))

"""
    prettyprint_diagnostic_info(filename_base::String, diagnostics; dedup=true)

Write `\$(filename_base).out` with a julia-readable pretty-printing
of an iterable of `edf_to_onda_samples` or `edf_header_to_onda_samples_info`
diagnostic `NamedTuples`.

If `dedup == true` (default), the diagnostics will be de-duplicated
based on the set of original EDF headers they each contain.

This is used by `test/import.jl`, and an example output can be found at
`test/test_edf_to_samples_info.in`.
"""
function prettyprint_diagnostic_info(filename_base::String, results; dedup=true)
    if dedup
        results = collect(values(Dict(_groupby(r) => r for r in results)))
    end
    filename = "$(filename_base).out"
    open(filename, "w") do f
        print(f, "$(filename_base) = ")
        prettyprint_diagnostic_info(f, results)
        println(f)
    end
end

