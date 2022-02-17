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

# XXX: make this @generated for speed:
function _named_tuple(x::T) where {T}
    fields = fieldnames(T)
    values = getfield.(Ref(x), fields)
    return NamedTuple{fields}(values)
end

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

"""
    match_edf_label(label, signal_names, channel_name, canonical_names)

Return a normalized label matched from and EDF `label`.  The purpose of this
function is to remove signal names from the label, and to canonicalize the
channel name(s) that remain.  So something like "[eCG] avl-REF" will be
transformed to "avl" (given `signal_names=["ecg"]`, and `channel_name="avl"`)

This returns `nothing` if `channel_name` does not match after normalization

Canonicalization

- ensures the given label is whitespace-stripped, lowercase, and parens-free
- strips trailing generic EDF references (e.g. "ref", "ref2", etc.)
- replaces all references with the appropriate name as specified by
  `canonical_names`
- replaces `+` with `_plus_` and `/` with `_over_`
- returns the initial reference name (w/o prefix sign, if present) and the
  entire label; the initial reference name should match the canonical channel
  name, otherwise the channel extraction will be rejected.

## Examples

```julia
match_edf_label("[ekG]  avl-REF", ["ecg", "ekg"], "avl", []) == "avl"
match_edf_label("ECG 2", ["ecg", "ekg"], "ii", ["ii" => ["2", "two", "ecg2"]]) == "ii"
```

See the tests for more examples

"""
function match_edf_label(label, signal_names, channel_name, canonical_names)
    label = _safe_lowercase(label)

    # ideally, we'd do the original behavior:
    # 
    # match exact STANDARD (or custom) signal types at beginning of label,
    # ignoring case possibly bracketed by or prepended with `[`, `]`, `,` or
    # whitespace everything after is included in the spec a.k.a. label
    #
    # for instance, if `signal_names = ["ecg", "ekg"]`, this would convert
    # - "[EKG] 2-REF"
    # - " eCg 2"
    # - ",ekg,2"
    #
    # into "2"
    #
    # however, the original behavior requires compiling and matching a different
    # regex for every possible `signal_names` entry (across all labels), for
    # every signal.  this adds ENORMOUS overhead compared to the rest of the
    # import pipeline (>90% of total time was spent in regex stuff) so instead
    # we do an approximation: treat ANYTHING between whitespace, [], or ',', as
    # teh signal, adn remove it (and the enclosing chars) if it is exactly equal
    # to any of the input `signal_names` (after lowercasing).
    #
    # This is not equivalent to the original behavior in only a handful of
    # cases
    # 
    # - if one of the `signal_names` is a suffix of the signal, like `"pap"`
    #   matching against `"xpap cpap"`.  the fix for this is to add the full
    #   signal name to the (end) of `signal_names` in the label set.
    # - if the signal name itself contains whitespace or one of `",[]"`, it
    #   will not match.  the fix for this is to pass a preprocessor function to
    #   `plan` to normalize known instances (after reviewing the plan)
    m = match(r"[\s\[,\]]*(?<signal>.+?)[\s,\]]*\s+(?<spec>.+)"i, label)
    if !isnothing(m) && m[:signal] in signal_names
        label = m[:spec]
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
function edf_signal_encoding(edf_signal_header, edf_seconds_per_record)
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

# TODO: replace this with float type for mismatched
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

# "channel"
canonical_channel_name(channel_name) = channel_name
# "channel" => ["alt1", "alt2", ...]
canonical_channel_name(channel_alternates::Pair) = first(channel_alternates)

plan(header::EDF.SignalHeader, s; kwargs...) = plan(_named_tuple(header), s; kwargs...)

function plan(header, seconds_per_record; labels=STANDARD_LABELS,
              units=STANDARD_UNITS, preprocess_labels=(l,t) -> l)
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
                    row = (; header...,
                           seconds_per_record,
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
        msg = let io = IOBuffer()
            println(io, "Skipping signal $(header.label): error while extracting channels")
            showerror(io, e, bt)
            String(take!(io))
        end

        @error msg
        
        return (; header..., seconds_per_record, error=SamplesInfoError(msg, e))
    end

    # nothing matched, return the original signal header (as a namedtuple)
    return (; header..., seconds_per_record)
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
    # remove non-Signals (e.g., AnnotationsSignals), keeping track of indices
    enum_signals = [(i, s) for (i, s) in enumerate(edf.signals) if s isa EDF.Signal]
    plan_rows = map(enum_signals) do (edf_signal_idx, signal)
        row = plan(signal.header, edf.header.seconds_per_record;
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
    plan_rows = Tables.rows(plan_table)
    exec_rows = map(collect(groupby(samples_groups, plan_rows))) do (idx, rows)
        try
            info = merge_samples_info(rows)
            if ismissing(info)
                # merge_samples_info returns missing is any of :kind,
                # :sample_unit, :sample_rate, or :channel is missing in any of
                # the rows, to indicate that it's not possible to generate
                # samples.  this keeps us from overwriting any existing, more
                # specific :errors in the plan with nonsense about promote_type
                # etc.
                samples = missing
            else
                signals = [edf.signals[row.edf_signal_idx] for row in rows]
                samples = onda_samples_from_edf_signals(info, signals,
                                                        edf.header.seconds_per_record)
            end
            return (; idx, samples, plan_rows=rows)
        catch e
            bt = catch_backtrace()
            io = IOBuffer()
            println(io, "Error executing OndaEDF plan for rows $(rows)")
            showerror(io, e, bt)
            @error String(take!(io))
            # this doesn't work (at least in IJulia) for some reason:
            # @error "Error executing OndaEDF plan for rows $(rows)" exception=(e, bt)
            
            return (; idx, samples=missing, plan_rows=Tables.rowmerge.(rows; error=e))
        end
    end

    sort!(exec_rows; by=(row -> row.idx))
    exec = Tables.columntable(exec_rows)

    exec_plan = reduce(vcat, exec.plan_rows)

    return collect(skipmissing(exec.samples)), exec_plan
end

function merge_samples_info(rows)
    # we enforce that kind, sample_unit, and sample_rate are all equal here
    key = unique(grouper((:kind, :sample_unit, :sample_rate)).(rows))
    if length(key) != 1
        throw(ArgumentError("couldn't merge samples info from rows: multiple " *
                            "kind/sample_unit/sample_rate combinations:\n\n" *
                            "$(keys)\n\n$(rows)"))
    end

    key = only(key)
    if any(ismissing, key) || any(ismissing, _get.(rows, :channel))
        # we use missing as a sentinel value to indicate that it's not possible
        # to create Samples from these rows
        return missing
    else
        onda_encoding = promote_encodings(rows)
        channels = [row.channel for row in rows]
        edf_channels = [row.label for row in rows]
        return SamplesInfo(; onda_encoding..., NamedTuple(key)..., channels, edf_channels)
    end
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

See the OndaEDF README for additional details regarding EDF formatting expectations.
"""
function store_edf_as_onda(edf::EDF.File, onda_dir, recording_uuid::UUID=uuid4();
                           import_annotations::Bool=true,
                           postprocess_samples=identity,
                           signals_prefix="edf", annotations_prefix=signals_prefix,
                           kwargs...)

    # Validate input argument early on
    signals_path = joinpath(onda_dir, "$(validate_arrow_prefix(signals_prefix)).onda.signals.arrow")
    annotations_path = joinpath(onda_dir, "$(validate_arrow_prefix(annotations_prefix)).onda.annotations.arrow")

    EDF.read!(edf)
    file_format = "lpcm.zst"

    # Trailing slash needed for compatibility with AWSS3.jl's `S3Path`
    mkpath(joinpath(onda_dir, "samples") * '/')

    signals = Onda.Signal[]
    edf_samples, plan = edf_to_onda_samples(edf; kwargs...)
    
    errors = _get(Tables.columns(plan), :errors)
    if !ismissing(errors)
        # why unique?  because errors that occur during execution get inserted
        # into all plan rows for that group of EDF signals, so they may be
        # repeated
        for e in unique(errors)
            @warn sprint(showerror, e)
        end
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

    return @compat (; recording_uuid, signals, annotations, signals_path, annotations_path, plan)
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
function edf_to_onda_samples(edf::EDF.File; kwargs...)
    signals_plan = plan(edf; kwargs...)
    EDF.read!(edf)
    samples, exec_plan = execute_plan(signals_plan, edf)
    return samples, exec_plan
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
