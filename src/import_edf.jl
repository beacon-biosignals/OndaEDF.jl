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

function _err_msg(e, msg="Error while converting EDF:")
    bt = catch_backtrace()
    msg = let io = IOBuffer()
        println(io, msg)
        showerror(io, e, bt)
        String(take!(io))
    end
    @error msg
    return msg
end

function _errored_row(row, e)
    msg = _err_msg(e, "Skipping signal $(row.label): error while extracting channels")
    return rowmerge(row; error=e)
end

function _errored_rows(rows, e)
    labels = [row.label for row in rows]
    labels_str = join(string.('"', labels, '"'), ", ", ", and ")
    msg = _err_msg(e, "Skipping signals $(labels_str): error while extracting channels")
    return rowmerge.(rows; error=e)
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

Return a normalized label matched from an EDF `label`.  The purpose of this
function is to remove signal names from the label, and to canonicalize the
channel name(s) that remain.  So something like "[eCG] avl-REF" will be
transformed to "avl" (given `signal_names=["ecg"]`, and `channel_name="avl"`)

This returns `nothing` if `channel_name` does not match after normalization.

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
    #   `plan_edf_to_onda_samples` to normalize known instances (after reviewing the plan)
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
    if any(any(ismissing, row) for row in encodings)
        return (sample_type=missing,
                sample_offset_in_unit=missing,
                sample_resolution_in_unit=missing,
                sample_rate=missing)
    end
    
    sample_type = mapreduce(promote_type, encodings) do e
        return Onda.julia_type_from_onda_sample_type(e.sample_type)
    end

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

# unpack a single channel spec from labels:
# "channel"
canonical_channel_name(channel_name) = channel_name
# "channel" => ["alt1", "alt2", ...]
canonical_channel_name(channel_alternates::Pair) = first(channel_alternates)

plan_edf_to_onda_samples(signal::EDF.Signal, s; kwargs...) = plan_edf_to_onda_samples(signal.header, s; kwargs...)
plan_edf_to_onda_samples(header::EDF.SignalHeader, s; kwargs...) = plan_edf_to_onda_samples(_named_tuple(header), s; kwargs...)

"""
    plan_edf_to_onda_samples(header, seconds_per_record; labels=STANDARD_LABELS,
                             units=STANDARD_UNITS, preprocess_labels=(l,t) -> l)
    plan_edf_to_onda_samples(signal::EDF.Signal, args...; kwargs...)

Formulate a plan for converting an EDF signal into Onda format.  This returns a
Tables.jl row with all the columns from the signal header, plus additional
columns for the `Onda.SamplesInfo` for this signal, and the `seconds_per_record`
that is passed in here.

If no labels match, then the `channel` and `kind` columns are `missing`; the
behavior of other `SamplesInfo` columns is undefined; they are currently set to
missing but that may change in future versions.

Any errors that are thrown in the process will be stored as `SampleInfoError`s
in the `error` column.

## Matching EDF label to Onda labels

The `labels` keyword argument determines how Onda `channel` and signal `kind`
are extracted from the EDF label.

Labels are specified as an iterable of `signal_names => channel_names` pairs.
`signal_names` should be an iterable of signal names, the first of which is the
canonical name used as the Onda `kind`.  Each element of `channel_names` gives
the specification for one channel, which can either be a string, or a
`canonical_name => alternates` pair.  Occurences of `alternates` will be
replaces with `canonical_name` in the generated channel label.

Matching is determined _solely_ by the channel names.  When matching, the signal
names are only used to remove signal names occuring as prefixes (e.g., "[ECG]
AVL") before matching channel names.  See [`match_edf_label`](@ref) for details,
and see `OndaEDF.STANDARD_LABELS` for the default labels.

As an example, here is (a subset of) the default labels for ECG signals:

```julia
["ecg", "ekg"] => ["i" => ["1"], "ii" => ["2"], "iii" => ["3"],
                   "avl"=> ["ecgl", "ekgl", "ecg", "ekg", "l"], 
                   "avr"=> ["ekgr", "ecgr", "r"], ...]
```

Matching is done in the order that `labels` iterates pairs, and will stop at the
first match, with no warning if signals are ambiguous (although this may change
in a future version)
"""
function plan_edf_to_onda_samples(header,
                                  seconds_per_record=_get(header,
                                                          :seconds_per_record);
                                  labels=STANDARD_LABELS,
                                  units=STANDARD_UNITS,
                                  preprocess_labels=(l,t) -> l)
    # we don't check this inside the try/catch because it's a user/method error
    # rather than a data/ingest error
    ismissing(seconds_per_record) && throw(ArgumentError(":seconds_per_record not found in header, or missing"))

    row = (; header..., seconds_per_record, error=nothing)

    try
        edf_label = preprocess_labels(header.label, header.transducer_type)
        for (signal_names, channel_names) in labels
            # channel names is iterable of channel specs, which are either "channel"
            # or "canonical => ["alt1", ...]
            for canonical in channel_names
                channel_name = canonical_channel_name(canonical)

                matched = match_edf_label(edf_label, signal_names, channel_name, channel_names)
                
                if matched !== nothing
                    # create SamplesInfo and return
                    row = rowmerge(row; 
                                   channel=matched,
                                   kind=first(signal_names),
                                   sample_unit=edf_to_onda_unit(header.physical_dimension, units),
                                   edf_signal_encoding(header, seconds_per_record)...)
                    return Plan(row)
                end
            end
        end
    catch e
        return Plan(_errored_row(row, e))
    end

    # nothing matched, return the original signal header (as a namedtuple)
    return Plan(row)
end

# create a table with a plan for converting this EDF file to onda: one row per
# signal, with the Onda.SamplesInfo fields that will be generated (modulo
# `promote_encoding`).  The column `onda_signal_idx` gives the planned grouping
# of EDF signals into Onda Samples.
#
# pass this plan to edf_to_onda_samples to actually run it

"""
    plan_edf_to_onda_samples(edf::EDF.File;
                             labels=STANDARD_LABELS,
                             units=STANDARD_UNITS,
                             preprocess_labels=(l,t) -> l,
                             onda_signal_groups=grouper((:kind, :sample_unit, :sample_rate)))

Formulate a plan for converting an `EDF.File` to Onda Samples.  This applies
`plan_edf_to_onda_samples` to each individual signal contained in the file,
storing `edf_signal_idx` as an additional column.  The resulting rows are then
grouped according to `onda_signal_grouper` (by default, the `:kind`,
`:sample_unit`, and `:sample_rate` columns), and the group index is added as an
additional column in `onda_signal_idx`.

The resulting plan is returned as a table.  No signal data is actually read from
the EDF file; to execute this plan and generate `Onda.Samples`, use
[`edf_to_onda_samples`](@ref)
"""
function plan_edf_to_onda_samples(edf::EDF.File;
                                  labels=STANDARD_LABELS,
                                  units=STANDARD_UNITS,
                                  preprocess_labels=(l,t) -> l,
                                  onda_signal_groups=grouper((:kind, :sample_unit, :sample_rate)))
    # remove non-Signals (e.g., AnnotationsSignals), keeping track of indices
    plan_rows = [rowmerge(plan_edf_to_onda_samples(s.header, edf.header.seconds_per_record;
                                                   labels, units, preprocess_labels);
                          edf_signal_idx=i)
                 for (i, s) in enumerate(edf.signals)
                 if s isa EDF.Signal]

    # group signals by which Samples they will belong to, promote_encoding, and
    # write index of destination signal into plan to capture grouping
    grouped_rows = groupby(onda_signal_groups, plan_rows)
    plan_rows = mapreduce(vcat, enumerate(values(grouped_rows))) do (onda_signal_idx, rows)
        encoding = promote_encodings(rows)
        return [rowmerge(row, encoding, (; onda_signal_idx)) for row in rows]
    end

    return FilePlan.(plan_rows)
end

_get(x, property) = hasproperty(x, property) ? getproperty(x, property) : missing
function grouper(vars=(:kind, :sample_unit, :sample_rate))
    return x -> NamedTuple{vars}(_get.(Ref(x), vars))
end

# return Samples for each :onda_signal_idx
"""
    edf_to_onda_samples(edf::EDF.File, plan_table; validate=true,
                        samples_groups=grouper((:onda_signal_idx, )))

Convert Signals found in an EDF File to `Onda.Samples` according to the plan
specified in `plan_table` (e.g., as generated by [`plan_edf_to_onda_samples`](@ref)), returning an
iterable of the generated `Onda.Samples` and the plan as actually executed.

The input plan is transformed by using [`merge_samples_info`](@ref) to combine
rows with the same `:onda_signal_idx` (or output of `sample_groups`) into a
common `Onda.SamplesInfo`.  Then [`onda_samples_from_edf_signals`](@ref) is used
to combine the EDF signals data into a single `Onda.Samples` per group.

The `label` of the original `EDF.Signal`s are preserved in the `:edf_channels`
field of the resulting `SamplesInfo`s for each `Samples` generated.

Any errors that occur are inserted into the `:error` column for the
corresponding rows from the plan.

Samples are returned in the order of `:onda_signal_idx` (or otherwise the output
of the `samples_groups` function).  Signals that could not be matched or
otherwise caused an error during execution are not returned.

If `validate=true` (the default), the plan is validated against the
[`FilePlan`](@ref) schema, and the signal headers in the `EDF.File`.
"""
function edf_to_onda_samples(edf::EDF.File, plan_table; validate=true,
                             samples_groups=grouper((:onda_signal_idx, )))
    if validate
        Legolas.validate(plan_table, Legolas.Schema("ondaedf-file-plan@1"))
        for row in Tables.rows(plan_table)
            signal = edf.signals[row.edf_signal_idx]
            signal.header.label == row.label ||
                throw(ArgumentError("Plan's label $(row.label) does not match EDF label $(signal.header.label)!"))
        end
    end
    EDF.read!(edf)
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
            plan_rows = _errored_rows(rows, e)
            return (; idx, samples=missing, plan_rows)
        end
    end

    sort!(exec_rows; by=(row -> row.idx))
    exec = Tables.columntable(exec_rows)

    exec_plan = reduce(vcat, exec.plan_rows)

    return collect(skipmissing(exec.samples)), exec_plan
end

"""
    merge_samples_info(plan_rows)

Create a single, merged `SamplesInfo` from plan rows, such as generated by
[`plan_edf_to_onda_samples`](@ref).  Encodings are promoted with `promote_encodings`.

The input rows must have the same values for `:kind`, `:sample_unit`, and
`:sample_rate`; otherwise an `ArgumentError` is thrown.

If any of these values is `missing`, or any row's `:channel` value is `missing`,
this returns `missing` to indicate it is not possible to determine a shared
`SamplesInfo`.

The original EDF labels are included in the output in the `:edf_channels`
column.
"""
function merge_samples_info(rows)
    # we enforce that kind, sample_unit, and sample_rate are all equal here
    key = unique(grouper((:kind, :sample_unit, :sample_rate)).(rows))
    if length(key) != 1
        throw(ArgumentError("couldn't merge samples info from rows: multiple " *
                            "kind/sample_unit/sample_rate combinations:\n\n" *
                            "$(pretty_table(String, key))\n\n" *
                            "$(pretty_table(String, rows))"))
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

Returns `(; recording_uuid, signals, annotations, signals_path, annotations_path, plan)`.

This is a convenience function that first formulates an import plan via
[`plan_edf_to_onda_samples`](@ref), and then immediately executes this plan with
[`edf_to_onda_samples`](@ref).

The samples and executed plan are returned; it is **strongly advised** that you
review the plan for un-extracted signals (where `:kind` or `:channel` is
`missing`) and errors (non-`nothing` values in `:error`).

Groups of `EDF.Signal`s are mapped as channels to `Onda.Samples` via
[`plan_edf_to_onda_samples`](@ref).  The caller of this function can control the
plan via the `labels`, `units`, and `preprocess_labels` keyword arguments, all
of which are forwarded to [`plan_edf_to_onda_samples`](@ref).

`EDF.Signal` labels that are converted into Onda channel names undergo the
following transformations:

- the label is whitespace-stripped, parens-stripped, and lowercased
- trailing generic EDF references (e.g. "ref", "ref2", etc.) are dropped
- any instance of `+` is replaced with `_plus_` and `/` with `_over_`
- all component names are converted to their "canonical names" when possible
  (e.g. "m1" in an EEG-matched channel name will be converted to "a1").

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
    
    errors = _get(Tables.columns(plan), :error)
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

    return (; recording_uuid, signals, annotations, signals_path, annotations_path, plan)
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
    edf_to_onda_samples(edf::EDF.File; kwargs...)

Read signals from an `EDF.File` into a vector of `Onda.Samples`.  This is a
convenience function that first formulates an import plan via [`plan_edf_to_onda_samples`](@ref),
and then immediately executes this plan with [`edf_to_onda_samples`](@ref).  The vector
of `Onda.Samples` and the executed plan are returned

The samples and executed plan are returned; it is **strongly advised** that you
review the plan for un-extracted signals (where `:kind` or `:channel` is
`missing`) and errors (non-`nothing` values in `:error`).

Collections of `EDF.Signal`s are mapped as channels to `Onda.Samples` via
[`plan_edf_to_onda_samples`](@ref).  The caller of this function can control the plan via the
`labels`, `units`, and `preprocess_labels` keyword arguments, all of
which are forwarded to [`plan_edf_to_onda_samples`](@ref).

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
    signals_plan = plan_edf_to_onda_samples(edf; kwargs...)
    EDF.read!(edf)
    samples, exec_plan = edf_to_onda_samples(edf, signals_plan)
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
