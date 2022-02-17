# these are preserved for posterity (temporarily) here


"""
    edf_header_to_onda_samples_info(edf::EDF.File; custom_extractors=STANDARD_EXTRACTORS)

Read edf header, return a mapping from `Onda.SamplesInfo`s to the vector
of `EDF.Signals` it was extracted from, along with a `NamedTuple` containing
diagnostic information in fields:
- `header_map`: a vector of corresponding `Onda.SamplesInfo`, `Vector{EDF.SignalHeader}` pairs.
- `unextracted_edf_headers`: a vector of EDF signal headers that could not be extracted.
- `errors`: vector of exceptions thrown while attempting to extract header info.

The `NamedTuple` can be pretty-printed and used to compare outputs with `SamplesInfo`s
previously extracted from the same data, for testing purposes.

`EDF.read!` does not get called, this function will work
with only the first few bytes--30k should be enough--of the edf file,
which is convenient for developping custom extractors for a dataset without
reading and converting all the samples data.
"""
function edf_header_to_onda_samples_info(edf::EDF.File; custom_extractors=STANDARD_EXTRACTORS)
    info_map, errors = try
        matched = []
        errors = Exception[]
        for extractor in custom_extractors
            extracteds, errs = extractor(edf)
            append!(errors, errs)
            for extracted in extracteds
                push!(matched, extracted)
            end
        end
        # each edf_signal should get extracted into at most one SamplesInfo, otherwise it is ambiguous
        matched_signals = Set(Iterators.flatten(map(last, matched)))
        ambiguous_edf_signals = []
        for edf_signal in matched_signals
            ambiguous_channels = _ambiguous_channels!(matched, edf_signal)
            if !isnothing(ambiguous_channels)
                edf_signal_summary = (edf_signal.header.label,
                                      edf_signal.header.transducer_type,
                                      edf_signal.header.physical_dimension)
                push!(errors, AmbiguousChannelError(edf_signal_summary => ambiguous_channels))
            end
        end
        matched = [(info, edf_signals) for (info, edf_signals) in matched if !isempty(info.channels)]
        sort!(errors; by=string)
        matched, errors
    catch e
        [], [e]
    end
    matched_edf_headers = mapreduce(last, union, info_map; init=[])
    unextracted = [s.header for s in edf.signals if isa(s, EDF.Signal) && s ∉ matched_edf_headers]
    header_map = [info => [s.header for s in edf_signals if isa(s, EDF.Signal)] for (info, edf_signals) in info_map]
    return info_map, (header_map=header_map,
                      unextracted_edf_headers=unextracted,
                      errors=errors)
end

function diagnostics_from_plan(plan)
    header_map = []
    unextracted = []
    errors = Exception[]

    rows = Tables.rows(plan)

    for row in rows
        err = _get(row, :error)
        if err isa Exception
            push!(errors, err)
        end
    end

    foreach(groupby(grouper((:onda_signal_idx, )), rows)) do (_, rows)
        headers = _signal_header.(rows)
        try
            if any(ismissing, _get.(rows, :channel))
                append!(unextracted, headers)
            else
                info = merge_samples_info(rows)
                push!(header_map, _samples_info(info) => headers)
            end
        catch e
            push!(errors, e)
            append!(unextracted, headers)
        end
    end

    return (; header_map, unextracted, errors)
end

function _signal_header(row)
    fields = fieldnames(EDF.SignalHeader)
    values = NamedTuple{fields}(NamedTuple(row))
    return EDF.SignalHeader(values...)
end

function _samples_info(row)
    fields = (:kind, :channels, :sample_unit, :sample_resolution_in_unit,
              :sample_offset_in_unit, :sample_type, :sample_rate)
    values = NamedTuple{fields}(NamedTuple(row))
    return Onda.SamplesInfo(; values...)
end

function diagnostics_table(diagnostics)
    header_map, unextracted_edf_headers, errors = diagnostics
    diag_table = []
    for (samplesinfo, headers) in header_map
        for (header, channel) in zip(headers, samplesinfo.channels)
            push!(diag_table, (; NamedTuple(samplesinfo)..., channel, _named_tuple(header)...))
        end
    end

    for header in unextracted_edf_headers
        push!(diag_table, _named_tuple(header))
    end

    return diag_table
end


