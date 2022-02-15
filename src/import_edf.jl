#= 

OndaEDF: a manifesto

this is a mess.  there are a two main problems with the current state of things:

1. There is a huge amount of indirection which makes the specification of
   extractors unnecessarily confusing and opaque.  It's very hard to tell what's
   going to happen when you make a change, and hard to tell what changes to make
   to achieve a desired outcome

2. It's harder than it should be to generate a persistent record of how one or
   more EDFs was converted to Onda format.  We should emit an "audit" table by
   default, which has one row per input signal, and the corresponding
   samplesinfo fields that were generated from it, where there's a 1-1 mapping
   between unique combinations of samplesinfo fields and Onda.Samples that are
   generated.

My proposal is this: 

1. Channel label extraction proceeds solely one signal at a time, and only takes
   the signal header or information derived from it.

2. The default extractor is a single function that iterates through a set of
   patterns, stopping at the first pattern that matches, and then quitting.

3. The output of this initial processing is a table with columns for the union
   of the fields in EDF.SignalHeader and Onda.SamplesInfo.  The Onda.SamplesInfo
   columns will be `missing` if extraction failed for some reason.  An
   additional column may optionally record the status (including any exceptions
   that occurred during any stage in processing).  

4. This table is The Plan for how to convert to Onda.  It may be manipulated
   programmatically before actually consuming the EDF.Signal data.  It should
   be consumed by any functions that actually deal with signal data

=# 




#####
##### `EDF.Signal` label handling
#####

# This function:
# - ensures the given label is whitespace-stripped, lowercase, and parens-free
# - strips trailing generic EDF references (e.g. "ref", "ref2", etc.)
# - replaces all references with the appropriate name as specified by `canonical_names`
# - replaces `+` with `_plus_` and `/` with `_over_`
# - returns the initial reference name (w/o prefix sign, if present) and the entire label;
#   the initial reference name should match the canonical channel name,
#   otherwise the channel extraction will be rejected.
function _normalize_references(original_label, canonical_names)
    label = replace(_safe_lowercase(original_label), r"\s"=>"")
    label = replace(replace(label, '('=>""), ')'=>"")
    label = replace(label, r"\*$"=>"")
    label = replace(label, '-'=>'…')
    label = replace(label, '+'=>"…+…")
    label = replace(label, '/'=>"…/…")
    m = match(r"^\[(.*)\]$", label)
    if m !== nothing
        label = only(m.captures)
    end
    parts = split(label, '…'; keepempty=false)
    final = findlast(part -> replace(part, r"\d" => "") != "ref", parts)
    parts = parts[1:something(final, 0)]
    isempty(parts) && return ("", "")
    for n in canonical_names
        if n isa Pair
            primary, alternatives = n
            primary = string(primary)
            for alternative in (string(a) for a in alternatives)
                for i in 1:length(parts)
                    if parts[i] == alternative
                        parts[i] = primary
                    end
                end
            end
        end
    end
    recombined = '-'^startswith(original_label, '-') * join(parts, '-')
    recombined = replace(recombined, "-+-"=>"_plus_")
    recombined = replace(recombined, "-/-"=>"_over_")
    return first(parts), recombined
end

_safe_lowercase(c::Char) = isvalid(c) ? lowercase(c) : c

# malformed UTF-8 chars are a choking hazard
_safe_lowercase(s::AbstractString) = map(_safe_lowercase, s)

function match_edf_label(label, signal_names, channel_name, canonical_names)
    label = _safe_lowercase(label)
    for signal_name in signal_names
        # match exact STANDARD (or custom) signal types at beginning of label, ignoring case
        # possibly bracketed by or prepended with `[`, `]`, `,` or whitespace
        # everything after is included in the spec a.k.a. label
        m = match(Regex("[\\s\\[,\\]]*$(signal_name)[\\s,\\]]*\\s+(?<spec>.+)", "i"), label)
        if !isnothing(m)
            label = m[:spec]
        end
        # if signal type does not match, use the entire label
    end
    label = replace(label, r"\s*-\s*" => "-")
    initial, normalized_label = _normalize_references(label, canonical_names)
    initial == channel_name && return normalized_label
    return nothing
end

#####
##### encodings
#####

struct MismatchedSampleRateError <: Exception
    sample_rates
end

function Base.showerror(io::IO, err::MismatchedSampleRateError)
    print(io, """
              found mismatched sample rate between channel encodings: $(err.sample_rates)

              OndaEDF does not currently automatically resolve mismatched sample rates;
              please preprocess your data before attempting `import_edf` so that channels
              of the same signal share a common sample rate.
              """)
end

# I wasn't super confident that the `sample_offset_in_unit` calculation I derived
# had the correctness/symmetry I was hoping it had, so basic algebra time (written
# so that you can try each step out in the REPL with random values):
#
#   res = (pmax - pmin) / (dmax - dmin)
#   pmax - (sample_resolution_in_unit * dmax) ≈ pmin - (sample_resolution_in_unit * dmin)
#   pmax - ((pmax * dmax - pmin * dmax) / (dmax - dmin)) ≈ pmin - ((pmax * dmin - pmin * dmin) / (dmax - dmin))
#   pmax - ((pmax * dmax - pmin * dmax) / (dmax - dmin)) + ((pmax * dmin - pmin * dmin) / (dmax - dmin)) ≈ pmin
#   pmax + ((pmin * dmax - pmax * dmax) / (dmax - dmin)) + ((pmax * dmin - pmin * dmin) / (dmax - dmin)) ≈ pmin
#   pmax + (pmin * dmax - pmax * dmax + pmax * dmin - pmin * dmin) / (dmax - dmin) ≈ pmin
#   pmax + (pmin * dmax + pmax * (-dmax) + pmax * dmin + pmin * (-dmin)) / (dmax - dmin) ≈ pmin
#   pmax + (pmax*(dmin - dmax) + pmin*(dmax - dmin)) / (dmax - dmin) ≈ pmin
#   pmax + pmin + (pmax*(dmin - dmax)/(dmax - dmin)) ≈ pmin
#   pmax + pmin + (-pmax) ≈ pmin
#   pmin ≈ pmin
function edf_signal_encoding(edf_signal_header::EDF.SignalHeader,
                             edf_seconds_per_record)
    dmin, dmax = edf_signal_header.digital_minimum, edf_signal_header.digital_maximum
    pmin, pmax = edf_signal_header.physical_minimum, edf_signal_header.physical_maximum
    sample_resolution_in_unit = (pmax - pmin) / (dmax - dmin)
    sample_offset_in_unit = pmin - (sample_resolution_in_unit * dmin)
    sample_rate = edf_signal_header.samples_per_record / edf_seconds_per_record
    sample_type = (dmax > typemax(Int16) || dmin < typemin(Int16)) ? Int32 : Int16
    return (sample_resolution_in_unit=Float64(sample_resolution_in_unit),
            sample_offset_in_unit=Float64(sample_offset_in_unit),
            sample_rate=Float64(sample_rate),
            sample_type=sample_type)
end

function promote_encodings(encodings; pick_offset=(_ -> 0.0), pick_resolution=minimum)
    sample_type = reduce(promote_type, (e.sample_type for e in encodings))

    sample_rates = [e.sample_rate for e in encodings]
    if all(==(first(sample_rates)), sample_rates)
        sample_rate = first(sample_rates)
    else
        throw(MismatchedSampleRateError(sample_rates))
    end

    offsets = [e.sample_offset_in_unit for e in encodings]
    if all(==(first(offsets)), offsets)
        sample_offset_in_unit = first(offsets)
    else
        sample_type = Int32
        sample_offset_in_unit = pick_offset(offsets)
    end

    resolutions = [e.sample_resolution_in_unit for e in encodings]
    if all(==(first(resolutions)), resolutions)
        sample_resolution_in_unit = first(resolutions)
    else
        sample_type = Int32
        sample_resolution_in_unit = pick_resolution(resolutions)
    end

    return (sample_type=sample_type,
            sample_offset_in_unit=sample_offset_in_unit,
            sample_resolution_in_unit=sample_resolution_in_unit,
            sample_rate=sample_rate)
end

#####
##### `EDF.Signal`s -> `Onda.Samples`
#####

function extract_channels(edf_signals, channel_matchers)
    extracted_channels = Pair{String,EDF.Signal}[]
    for channel_matcher in channel_matchers
        for edf_signal in edf_signals
            edf_signal isa EDF.Signal || continue
            any(x -> last(x) === edf_signal, extracted_channels) && continue
            channel_name = channel_matcher(edf_signal)
            channel_name === nothing && continue
            push!(extracted_channels, channel_name => edf_signal)
        end
    end
    return extracted_channels
end

"""
    edf_signals_to_samplesinfo(edf, edf_signals, kind, channel_names, samples_per_record; unit_alternatives=STANDARD_UNITS)

Generate a single `Onda.SamplesInfo` for the given collection of `EDF.Signal`s
corresponding to the channels of a single Onda signal.  Sample units are
converted to Onda units and checked for consistency, and a promoted encoding
(resolution, offset, and sample type/rate) is generated.

No conversion of the actual signals is performed at this step.
"""
function edf_signals_to_samplesinfo(edf::EDF.File, edf_signals::Vector{<:EDF.Signal}, kind, channel_names; unit_alternatives=STANDARD_UNITS)
    onda_units = map(s -> edf_to_onda_unit(s.header.physical_dimension, unit_alternatives), edf_signals)
    onda_sample_unit = first(onda_units)

    edf_encodings = map(s -> edf_signal_encoding(s.header, edf.header.seconds_per_record), edf_signals)
    onda_encoding = promote_encodings(edf_encodings)

    info = SamplesInfo(; kind=kind, channels=channel_names,
                       sample_unit=string(onda_sample_unit),
                       sample_resolution_in_unit=onda_encoding.sample_resolution_in_unit,
                       sample_offset_in_unit=onda_encoding.sample_offset_in_unit,
                       sample_type=onda_encoding.sample_type,
                       sample_rate=onda_encoding.sample_rate)
    return info
end

struct SamplesInfoError <: Exception
    msg::String
    cause::Exception
end

function Base.showerror(io::IO, e::SamplesInfoError)
    print(io, "SamplesInfoError: ", e.msg, " caused by: ")
    Base.showerror(io, e.cause)
end

function groupby(f, list)
    d = Dict()
    for v in list
        push!(get!(d, f(v), Vector{eltype(list)}()), v)
    end
    return d
end

"""
    extract_channels_by_label(edf::EDF.File, signal_names, channel_names;
                              unit_alternatives=STANDARD_UNITS, preprocess_labels=(l,t) -> l)

For one or more signal names and one or more channel names,
return a list of `[(infos, errors)...]` where `errors` is a vector of errors that occurred,
and `infos` is a vector of `(si::Onda.SamplesInfo, edf_signals::Vector{EDF.Signal})`,
where `edf_signals` align with `si.channel`. This list can have more than one pair
if channels with the same signal kind/type have different sample rates or
physical units.

`(label, transducer_type)` pairs will be transformed into labels by `preprocess_labels`
(default preprocessor returns the original label). An alternate to `STANDARD_UNITS`
for mapping different spellings of units to their canonical unit name can be passed in
as `unit_alternatives`.

`errors` contains `SamplesInfoError`s thrown if channels corresponding to a signal
were extracted but an error occured while interpreting physical units,
while promoting sample encodings, or otherwise constructing a `SamplesInfo`.

`signal_names` should be an iterable of `String`s naming the signal types to
extract (e.g., `["ecg", "ekg"]`; `["eeg"]`).

`channel_names` should be an iterable of channel specifications, each of which
can be either a `String` giving the generated channel name, or a `Pair` mapping
a canonical name to a list of alternatives that it should be substituted for
(e.g., `"canonical_name" => ["alt1", "alt2", ...]`).

`unit_alternatives` lists standardized unit names and alternatives that map to them.
See `OndaEDF.STANDARD_UNITS` for defaults.

`preprocess_labels(label::String, transducer_type::String)` is applied to raw edf signal header labels
beforehand; defaults to returning `label`.

See `OndaEDF.STANDARD_LABELS` for the labels (`signal_names => channel_names`
`Pair`s) that are used to extract EDF signals by default.

"""
function extract_channels_by_label(edf::EDF.File, signal_names, channel_names;
                                   unit_alternatives=STANDARD_UNITS, preprocess_labels=(l,t) -> l)
    matcher = x -> begin
        # yo I heard you like closures
        # x is either a channel name (string), or a channel_name => alternatives Pair.
        this_channel_name = x isa Pair ? first(x) : x
        return s -> match_edf_label(preprocess_labels(s.header.label, s.header.transducer_type),
                                    signal_names,
                                    this_channel_name,
                                    channel_names)
    end
    edf_channels = extract_channels(edf.signals, (matcher(x) for x in channel_names))

    # place channels with different physical units or sample rates in separate Onda signals
    grouped = groupby(edf_channels) do p
        channel_name, edf_signal = p
        return ((edf_signal.header.samples_per_record / edf.header.seconds_per_record), edf_signal.header.physical_dimension)
    end

    results = map(values(grouped)) do pairs
        # pairs is a vector of `standard_onda_name::String => EDF.Signal` pairs
        edf_channel_names, edf_channels = zip(pairs...)
        try
            edf_channels = collect(edf_channels)
            info = edf_signals_to_samplesinfo(edf, edf_channels, first(signal_names), collect(edf_channel_names))
            return info, edf_channels
        catch e
            # do not throw, but return any errors
            units = [s.header.label => s.header.physical_dimension for s in edf_channels]
            msg ="""Skipping signal: error while processing units and encodings
                    for $(first(signal_names)) signal with units $units"""
            return SamplesInfoError(msg, e)
        end
    end

    return ([info_channels for info_channels in results if !isa(info_channels, Exception)],
            [e for e in results if isa(e, Exception)])
end

# "channel"
canonical_channel_name(channel_name) = channel_name
# "channel" => ["alt1", "alt2", ...]
canonical_channel_name(channel_alternates::Pair) = first(channel_alternates)

function extract_channels_by_label(header::EDF.SignalHeader,
                                   seconds_per_record;
                                   labels=STANDARD_LABELS,
                                   units=STANDARD_UNITS,
                                   preprocess_labels=(l,t) -> l)
    edf_label = preprocess_labels(header.label, header.transducer_type)

    try
        for (signal_names, channel_names) in labels
            # channel names is iterable of channel specs, which are either "channel"
            # or "canonical => ["alt1", ...]
            for canonical in channel_names
                channel_name = canonical_channel_name(canonical)

                matched = match_edf_label(edf_label, signal_names, channel_name, channel_names)
                
                if matched !== nothing
                    # create SamplesInfo and return
                    row = (; _named_tuple(header)...,
                           channel=matched,
                           kind=first(signal_names),
                           sample_unit=edf_to_onda_unit(header.physical_dimension, units),
                           edf_signal_encoding(header, seconds_per_record)..., )
                    return row
                end
            end
        end
    catch e
        bt = catch_backtrace()
        st = stacktrace(bt)
        msg = """Skipping signal $(header.label): error while extracting channels:\n\n$(st)"""
        return (; _named_tuple(header)..., error=SamplesInfoErr(msg, e))
    end

    # nothing matched, return the original signal header
    return _named_tuple(header)
end

# create a table with a plan for converting this EDF file to onda: one row per
# signal, with the Onda.SamplesInfo fields that will be generated (modulo
# `promote_encoding`).  The column `onda_signal_idx` gives the planned grouping
# of EDF signals into Onda Samples.
#
# pass this plan to execute_plan to actually run it
function plan(edf::EDF.File;
              labels=STANDARD_LABELS,
              units=STANDARD_UNITS,
              preprocess_labels=(l,t) -> l,
              onda_signal_groups=grouper((:kind, :sample_unit, :sample_rate)))
    # remove AnnotationsSignals, keeping track of indices
    enum_signals = [(i, s) for (i, s) in enumerate(edf.signals) if s isa EDF.Signal]
    plan_rows = map(enum_signals) do (edf_signal_idx, signal)
        row = extract_channels_by_label(signal.header,
                                        edf.header.seconds_per_record;
                                        labels, units, preprocess_labels)
        return Tables.rowmerge(row; edf_signal_idx)
    end

    # write index of destination signal into plan to capture grouping
    grouped_rows = groupby(onda_signal_groups, plan_rows)
    plan_rows = mapreduce(vcat, enumerate(values(grouped_rows))) do (onda_signal_idx, rows)
        return Tables.rowmerge.(rows; onda_signal_idx)
    end

    # make sure we get a well-behaved Tables.jl table out of this
    return Tables.dictrowtable(plan_rows)
end

_get(x, property) = hasproperty(x, property) ? getproperty(x, property) : missing
function grouper(vars=(:kind, :sample_unit, :sample_rate))
    return x -> NamedTuple{vars}(_get.(Ref(x), vars))
end

# return Samples for each :onda_signal_idx
function execute_plan(plan_table, edf::EDF.File;
                      samples_groups=grouper((:onda_signal_idx, )))
    rows = Tables.rows(plan_table)
    output = map(collect(groupby(samples_groups, rows))) do (idx, rows)
        try
            info = merge_samples_info(rows)
            signals = [edf.signals[row.edf_signal_idx] for row in rows]
            samples = onda_samples_from_edf_signals(info, signals,
                                                    edf.header.seconds_per_record)
            return (; samples, plan_rows=rows, error=nothing)
        catch e
            bt = catch_backtrace()
            io = IOBuffer()
            println(io, "Error executing OndaEDF plan for rows $(rows)")
            showerror(io, e, bt)
            @error String(take!(io))
            # this doesn't work (at least in IJulia) for some reason:
            # @error "Error executing OndaEDF plan for rows $(rows)" exception=(e, bt)
            return (; samples=missing, plan_rows=rows, error=e)
        end
    end
end

function merge_samples_info(rows)
    # we enforce that kind, sample_unit, and sample_rate are all equal here
    key = unique(grouper((:kind, :sample_unit, :sample_rate)), rows)
    if length(key) != 1
        throw(ArgumentError("couldn't merge samples info from rows: multiple " *
                            "kind/sample_unit/sample_rate combinations:\n\n" *
                            "$(keys)\n\n$(rows)"))
    end

    key = only(key)
    onda_encoding = promote_encodings(rows)
    channels = [row.channel for row in rows]
    return SamplesInfo(; onda_encoding..., key..., channels, edf_source=rows)
end

#####
##### `import_edf!`
#####

function onda_samples_from_edf_signals(target::Onda.SamplesInfo, edf_signals,
                                       edf_seconds_per_record)
    sample_count = length(first(edf_signals).samples)
    if !all(length(s.samples) == sample_count for s in edf_signals)
        error("mismatched sample counts between `EDF.Signal`s: ", [length(s.samples) for s in edf_signals])
    end
    sample_data = Matrix{sample_type(target)}(undef, length(target.channels), sample_count)
    for (i, edf_signal) in enumerate(edf_signals)
        edf_encoding = edf_signal_encoding(edf_signal.header, edf_seconds_per_record)
        if target.sample_rate != edf_encoding.sample_rate
            throw(MismatchedSampleRateError((target.sample_rate, edf_encoding.sample_rate)))
        end
        if (target.sample_resolution_in_unit != edf_encoding.sample_resolution_in_unit ||
            target.sample_offset_in_unit != edf_encoding.sample_offset_in_unit ||
            sample_type(target) != eltype(edf_signal.samples))
            decoded_samples = Onda.decode(edf_encoding.sample_resolution_in_unit,
                                          edf_encoding.sample_offset_in_unit,
                                          edf_signal.samples)
            encoded_samples = Onda.encode(sample_type(target), target.sample_resolution_in_unit,
                                          target.sample_offset_in_unit, decoded_samples,
                                          missing)
        else
            encoded_samples = edf_signal.samples
        end
        copyto!(view(sample_data, i, :), encoded_samples)
    end
    return Samples(sample_data, target, true)
end

"""
    store_edf_as_onda(edf::EDF.File, onda_dir, recording_uuid::UUID=uuid4();
                      custom_extractors=STANDARD_EXTRACTORS, import_annotations::Bool=true,
                      postprocess_samples=identity,
                      signals_prefix="edf", annotations_prefix=signals_prefix)

Convert an EDF.File to `Onda.Samples` and `Onda.Annotation`s, store the samples
in `\$path/samples/`, and write the Onda signals and annotations tables to
`\$path/\$(signals_prefix).onda.signals.arrow` and
`\$path/\$(annotations_prefix).onda.annotations.arrow`.  The default prefix is
"edf", and if a prefix is provided for signals but not annotations both will use
the signals prefix.  The prefixes cannot reference (sub)directories.

Returns `(; recording_uuid, signals, annotations, signals_path, annotations_path)`.

Samples are extracted with [`edf_to_onda_samples`](@ref), and EDF+ annotations are
extracted with [`edf_to_onda_annotations`](@ref) if `import_annotations==true`
(the default).

Collections of `EDF.Signal`s are mapped as channels to `Onda.Signal`s via simple
"extractor" callbacks of the form:

    edf::EDF.File -> (samples_info::Onda.SamplesInfo,
                      edf_signals::Vector{EDF.Signal})

`store_edf_as_onda` automatically uses a variety of default extractors derived
from the EDF standard texts; see `src/standards.jl` and
[`extract_channels_by_label`](@ref) for details. The caller can provide
alternative extractors via the `custom_extractors` keyword argument, and the
[`edf_signals_to_samplesinfo`](@ref) utility can be used to extract a common
`Onda.SamplesInfo` from a collection of EDF.Signals.

`EDF.Signal` labels that are converted into Onda channel names undergo the
following transformations:

- the label's prepended signal type is matched against known types, if present
- the remainder of the label is whitespace-stripped, parens-stripped, and lowercased
- trailing generic EDF references (e.g. "ref", "ref2", etc.) are dropped
- any instance of `+` is replaced with `_plus_` and `/` with `_over_`
- all component names are converted to their "canonical names" when possible
  (e.g. for an EOG matched channel, "eogl", "loc", "lefteye", etc. are converted
  to "left").

`EDF.Signal`s which get extracted into more than one `Onda.Samples` are removed
and an `AmbiguousChannelError` displayed as a warning.

See the OndaEDF README for additional details regarding EDF formatting expectations.
"""
function store_edf_as_onda(edf::EDF.File, onda_dir, recording_uuid::UUID=uuid4();
                           custom_extractors=STANDARD_EXTRACTORS, import_annotations::Bool=true,
                           postprocess_samples=identity,
                           signals_prefix="edf", annotations_prefix=signals_prefix)

    # Validate input argument early on
    signals_path = joinpath(onda_dir, "$(validate_arrow_prefix(signals_prefix)).onda.signals.arrow")
    annotations_path = joinpath(onda_dir, "$(validate_arrow_prefix(annotations_prefix)).onda.annotations.arrow")

    EDF.read!(edf)
    file_format = "lpcm.zst"

    # Trailing slash needed for compatibility with AWSS3.jl's `S3Path`
    mkpath(joinpath(onda_dir, "samples") * '/')

    signals = Onda.Signal[]
    edf_samples, diagnostics = edf_to_onda_samples(edf; custom_extractors=custom_extractors)
    for e in diagnostics.errors
        @warn sprint(showerror, e)
    end
    edf_samples = postprocess_samples(edf_samples)
    for samples in edf_samples
        sample_filename = string(recording_uuid, "_", samples.info.kind, ".", file_format)
        file_path = joinpath(onda_dir, "samples", sample_filename)
        signal = store(file_path, file_format, samples, recording_uuid, Second(0))
        push!(signals, signal)
    end

    write_signals(signals_path, signals)
    if import_annotations
        annotations = edf_to_onda_annotations(edf, recording_uuid)
        if !isempty(annotations)
            write_annotations(annotations_path, annotations)
        else
            @warn "No annotations found in $onda_dir"
            annotations_path = nothing
        end
    else
        annotations = Onda.Annotation[]
    end

    return @compat (; recording_uuid, signals, annotations, signals_path, annotations_path)
end

function store_edf_as_onda(path, edf::EDF.File, uuid::UUID=uuid4(); kwargs...)
    Base.depwarn("`store_edf_as_onda(path, edf, ...)` is deprecated, use " *
                 "`nt = store_edf_as_onda(edf, path, ...); nt.recording_uuid => (nt.signals, nt.annotations)` " *
                 "instead.",
                 :store_edf_as_onda)
    nt = store_edf_as_onda(edf, path, uuid; kwargs...)
    signals = [rowmerge(s; file_path=string(s.file_path)) for s in nt.signals]
    return nt.recording_uuid => (nt.signals, nt.annotations)
end

function validate_arrow_prefix(prefix)
    prefix == basename(prefix) || throw(ArgumentError("prefix \"$prefix\" is invalid: cannot contain directory separator"))
    pm = match(r"(.*)\.onda\.(signals|annotations)\.arrow", prefix)
    if pm !== nothing
        @warn "Extracting prefix \"$(pm.captures[1])\" from provided prefix \"$prefix\""
        prefix = pm.captures[1]
    end
    return prefix
end

# the same EDF.Signal was extracted into multiple `Onda.SampleInfos`.
struct AmbiguousChannelError <: Exception
    summary
end

Base.showerror(io::IO, e::AmbiguousChannelError) = print(io, "AmbiguousChannelError: the same `EDF.Signal` was extracted into multiple `Onda.SampleInfo`s\n", e.summary)

# return a list of tuples describing sample info channels that are ambiguous
# because they were extracted from the same edf_signal
# modifies `infos` and associated `edf_signals::Vector{EDF.Signal}` in place to remove ambiguous signals
function _ambiguous_channels!(extracted, edf_signal)
    ambiguous = []
    for (info, edf_signals) in extracted
        i = findfirst(==(edf_signal), edf_signals)
        isnothing(i) && continue
        channel_name = info.channels[i]
        summary = (info.kind, channel_name, info.sample_unit)
        push!(ambiguous, (info, edf_signals) => summary)
    end
    length(ambiguous) < 2 && return nothing
    for ((info, edf_signals), (_, channel_name, _)) in ambiguous
        filter!(!=(channel_name), info.channels)
        filter!(!=(edf_signal), edf_signals)
    end
    return map(last, ambiguous)
end

"""
    edf_to_onda_samples(edf::EDF.File; custom_extractors=())

Read signals from an `EDF.File` into a vector of `Onda.Samples`,
which are returned along with a NamedTuple with diagnostic information
(the same info returned by [`edf_header_to_onda_samples_info`](@ref)).

Collections of `EDF.Signal`s are mapped as channels to `Onda.Signal`s via simple
"extractor" callbacks of the form:

    edf::EDF.File -> (samples_info::Onda.SamplesInfo,
                      edf_signals::Vector{EDF.Signal})

`edf_to_onda_samples` automatically uses a variety of default extractors derived from
the EDF standard texts; see `src/standards.jl` for details. The caller can also
provide additional extractors via the `custom_extractors` keyword argument.

`EDF.Signal` labels that are converted into Onda channel names undergo the
following transformations:

- the label is whitespace-stripped, parens-stripped, and lowercased
- trailing generic EDF references (e.g. "ref", "ref2", etc.) are dropped
- any instance of `+` is replaced with `_plus_` and `/` with `_over_`
- all component names are converted to their "canonical names" when possible
  (e.g. "m1" in an EEG-matched channel name will be converted to "a1").

See the OndaEDF README for additional details regarding EDF formatting expectations.
"""
function edf_to_onda_samples(edf::EDF.File; custom_extractors=STANDARD_EXTRACTORS)
    EDF.read!(edf)
    info_map, nt = edf_header_to_onda_samples_info(edf; custom_extractors=custom_extractors)
    edf_samples = [onda_samples_from_edf_signals(info,
                                                 edf_signals,
                                                 edf.header.seconds_per_record)
                   for (info, edf_signals) in info_map if !isempty(info.channels)]
    return edf_samples, nt
end

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

function _named_tuple(x::T) where {T}
    fields = fieldnames(T)
    values = getfield.(Ref(x), fields)
    return NamedTuple{fields}(values)
end



function diagnostics_table(diagnostics)
    (; header_map, unextracted_edf_headers, errors) = diagnostics
    diag_table = []
    for (samplesinfo, headers) in header_map
        for (header, channels) in zip(headers, samplesinfo.channels)
            push!(diag_table, (; NamedTuple(samplesinfo)..., channels, _named_tuple(header)...))
        end
    end

    for header in unextracted_edf_headers
        push!(diag_table, _named_tuple(header))
    end

    return diag_table
end




"""
    edf_to_onda_annotations(edf::EDF.File, uuid::UUID)

Extract EDF+ annotations from an `EDF.File` for recording with ID `uuid` and
return them as a vector of `Onda.Annotation`s.  Each returned annotation has
a  `value` field that contains the string value of the corresponding EDF+
annotation.

If no EDF+ annotations are found in `edf`, then an empty `Vector{Annotation}` is
returned.
"""
function edf_to_onda_annotations(edf::EDF.File, uuid::UUID)
    EDF.read!(edf)
    annotations = Annotation[]
    for annotation_signal in edf.signals
        annotation_signal isa EDF.AnnotationsSignal || continue
        for record in annotation_signal.records
            for tal in record
                start_nanosecond = Nanosecond(round(Int, 1e9 * tal.onset_in_seconds))
                if tal.duration_in_seconds === nothing
                    stop_nanosecond = start_nanosecond
                else
                    stop_nanosecond = start_nanosecond + Nanosecond(round(Int, 1e9 * tal.duration_in_seconds))
                end
                for annotation_string in tal.annotations
                    isempty(annotation_string) && continue
                    annotation = Annotation(; recording=uuid, id=uuid4(),
                                            span=TimeSpan(start_nanosecond, stop_nanosecond),
                                            value=annotation_string)
                    push!(annotations, annotation)
                end
            end
        end
    end
    return annotations
end
