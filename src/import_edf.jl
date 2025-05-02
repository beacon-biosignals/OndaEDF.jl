@generated function _named_tuple(x)
    names = fieldnames(x)
    types = Tuple{fieldtypes(x)...}
    body = Expr(:tuple)
    for i in 1:fieldcount(x)
        push!(body.args, :(getfield(x, $i)))
    end
    return :(NamedTuple{$names,$types}($body))
end

function _err_msg(e, msg="Error while converting EDF:")
    bt = catch_backtrace()
    msg *= '\n' * sprint(showerror, e, bt)
    @error msg
    return msg
end

_merge(row; kwargs...) = rowmerge(row; kwargs...)
_merge(row::Legolas.AbstractRecord; kwargs...) = Legolas.record_merge(row; kwargs...)

function _errored_row(row, e)
    msg = _err_msg(e, "Skipping signal $(row.label): error while extracting channels")
    return _merge(row; error=msg)
end

function _errored_rows(rows, e)
    labels = [row.label for row in rows]
    labels_str = join(string.('"', labels, '"'), ", ", ", and ")
    msg = _err_msg(e, "Skipping signals $(labels_str): error while extracting channels")
    return _merge.(rows; error=msg)
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
            primary = lowercase(string(primary))
            for alternative in (lowercase(string(a)) for a in alternatives)
                for i in eachindex(parts)
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
    OndaEDF.match_edf_label(label, signal_names, channel_name, canonical_names)

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

!!! note

    This is an internal function and is not meant to be called directly.

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
    #   will not match.  the fix for this is to preprocess signal headers before
    #   `plan_edf_to_onda_samples` to normalize known instances (after reviewing the plan)
    m = match(r"[\s\[,\]]*(?<signal>.+?)[\s,\]]*\s+(?<spec>.+)"i, label)
    if !isnothing(m) && m[:signal] in Iterators.map(lowercase, signal_names)
        label = m[:spec]
    end

    label = replace(label, r"\s*-\s*" => "-")
    initial, normalized_label = _normalize_references(label, canonical_names)
    initial == lowercase(channel_name) && return normalized_label
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
    sample_type = (dmax > typemax(Int16) || dmin < typemin(Int16)) ? "int32" : "int16"
    return (sample_resolution_in_unit=Float64(sample_resolution_in_unit),
            sample_offset_in_unit=Float64(sample_offset_in_unit),
            sample_rate=Float64(sample_rate),
            sample_type=sample_type)
end

# TODO: replace this with float type for mismatched
"""
    promote_encodings(encodings; pick_offset=(_ -> 0.0), pick_resolution=minimum)

Return a common encoding for input `encodings`, as a `NamedTuple` with fields
`sample_type`, `sample_offset_in_unit`, `sample_resolution_in_unit`, and
`sample_rate`.  If input encodings' `sample_rate`s are not all equal, an error
is thrown.  If sample rates/offests are not equal, then `pick_offset` and
`pick_resolution` are used to combine them into a common offset/resolution.

!!! note

    This is an internal function and is not meant to be called direclty.
"""
function promote_encodings(encodings; pick_offset=(_ -> 0.0), pick_resolution=minimum)
    encoding_fields = (:sample_rate,
                       :sample_offset_in_unit,
                       :sample_resolution_in_unit,
                       :sample_type)
    if any(ismissing,
           getproperty(row, p)
           for p in encoding_fields
           for row in encodings)
        return (; sample_type=missing,
                sample_offset_in_unit=missing,
                sample_resolution_in_unit=missing,
                sample_rate=missing)
    end

    sample_type = mapreduce(Onda.sample_type, promote_type, encodings)

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

    return (sample_type=Onda.onda_sample_type_from_julia_type(sample_type),
            sample_offset_in_unit=sample_offset_in_unit,
            sample_resolution_in_unit=sample_resolution_in_unit,
            sample_rate=sample_rate)
end

#####
##### `EDF.Signal`s -> `Onda.Samples`
#####

const SAMPLES_ENCODED_WARNING = """
                                !!! warning
                                    Returned samples are integer-encoded. If these samples are being serialized out (e.g. via `Onda.store!`)
                                    this is not an issue, but if the samples are being immediately analyzed in memory, call `Onda.decode`
                                    to decode them to recover the time-series voltages.
                                """

struct SamplesInfoError <: Exception
    msg::String
    cause::Exception
end

function Base.showerror(io::IO, e::SamplesInfoError)
    print(io, "SamplesInfoError: ", e.msg, " caused by: ")
    Base.showerror(io, e.cause)
end

function groupby(f, list)
    d = OrderedDict()
    for v in list
        push!(get!(d, f(v), Vector{Any}()), v)
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
                             units=STANDARD_UNITS)
    plan_edf_to_onda_samples(signal::EDF.Signal, args...; kwargs...)

Formulate a plan for converting an EDF signal into Onda format.  This returns a
Tables.jl row with all the columns from the signal header, plus additional
columns for the `Onda.SamplesInfo` for this signal, and the `seconds_per_record`
that is passed in here.

If no labels match, then the `channel` and `sensor_type` columns are `missing`; the
behavior of other `SamplesInfo` columns is undefined; they are currently set to
missing but that may change in future versions.

Any errors that are thrown in the process will be wrapped as `SampleInfoError`s
and then printed with backtrace to a `String` in the `error` column.

## Matching EDF label to Onda labels

The `labels` keyword argument determines how Onda `channel` and signal `sensor_type`
are extracted from the EDF label.

Labels are specified as an iterable of `signal_names => channel_names` pairs.
`signal_names` should be an iterable of signal names, the first of which is the
canonical name used as the Onda `sensor_type`.  Each element of `channel_names` gives
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
                                  preprocess_labels=nothing)
    # we don't check this inside the try/catch because it's a user/method error
    # rather than a data/ingest error
    ismissing(seconds_per_record) && throw(ArgumentError(":seconds_per_record not found in header, or missing"))

    # keep the kwarg so we can throw a more informative error
    if preprocess_labels !== nothing
        throw(ArgumentError("the `preprocess_labels` argument has been removed.  " *
                            "Instead, preprocess signal header rows to before calling " *
                            "`plan_edf_to_onda_samples`"))
    end

    row = (; header..., seconds_per_record, error=nothing)

    try
        # match physical units and encoding first so that we give users better
        # feedback about _which_ thing (labels vs. units) didn't match.
        #
        # still do it in the try/catch in case edf_to_onda_unit or
        # edf_signal_encoding throws an error
        row = rowmerge(row;
                       sample_unit=edf_to_onda_unit(header.physical_dimension, units),
                       edf_signal_encoding(header, seconds_per_record)...)

        edf_label = header.label
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
                                   sensor_type=first(signal_names))
                    return PlanV4(row)
                end
            end
        end
    catch e
        e isa InterruptException && rethrow()
        return PlanV4(_errored_row(row, e))
    end

    # nothing matched, return the original signal header (as a namedtuple)
    return PlanV4(row)
end

"""
    plan_edf_to_onda_samples(edf::EDF.File;
                             labels=STANDARD_LABELS,
                             units=STANDARD_UNITS,
                             extra_onda_signal_groupby=())

Formulate a plan for converting an `EDF.File` to Onda Samples.  This applies
`plan_edf_to_onda_samples` to each individual signal contained in the file,
storing `edf_signal_index` as an additional column.

The resulting rows are then passed to [`plan_edf_to_onda_samples_groups`](@ref)
and grouped according to the `:sensor_type`, `:sample_unit`, and `:sample_rate`
columns, as well as any additional columns specified in
`extra_onda_signal_groupby`.  A `sensor_label` is generated for each group,
based on the `sensor_type` but with a numeric suffix `_n` for the `n`th
occurance of a `sensor_type` after the first.

The resulting plan is returned as a table.  No signal data is actually read from
the EDF file; to execute this plan and generate `Onda.Samples`, use
[`edf_to_onda_samples`](@ref).  The index of the EDF signal (after filtering out
signals that are not `EDF.Signal`s, e.g. annotation channels) for each row is
stored in the `:edf_signal_index` column, and the rows are sorted in order of
`:sensor_label`, and then by `:edf_signal_index`.
"""
function plan_edf_to_onda_samples(edf::EDF.File;
                                  labels=STANDARD_LABELS,
                                  units=STANDARD_UNITS,
                                  extra_onda_signal_groupby=())
    true_signals = filter(x -> isa(x, EDF.Signal), edf.signals)
    plan_rows = map(true_signals) do s
        return plan_edf_to_onda_samples(s.header, edf.header.seconds_per_record;
                                        labels, units)
    end

    # group signals by which Samples they will belong to, promote_encoding, and
    # write index of destination signal into plan to capture grouping
    plan_rows = plan_edf_to_onda_samples_groups(plan_rows; extra_onda_signal_groupby)

    return FilePlanV4.(plan_rows)
end

"""
    plan_edf_to_onda_samples_groups(plan_rows; extra_onda_signal_groupby=())

Group together `plan_rows` based on the values of the `:sensor_type`,
`:sample_unit`, `:sample_rate`, and `extra_onda_signal_groupby` columns,
creating a unique `:sensor_label` per group and and promoting the Onda encodings
for each group using [`OndaEDF.promote_encodings`](@ref).  All rows with the
same `:sensor_label` will be combined into a single Onda Samples by
[`edf_to_onda_samples`](@ref).

If the `:edf_signal_index` column is not present or otherwise missing, it will
be filled in based on the order of the input rows.

The updated rows are returned, sorted first by the grouping columns and second
by order of occurrence within the input rows.
"""
function plan_edf_to_onda_samples_groups(plan_rows;
                                         extra_onda_signal_groupby=())
    plan_rows = Tables.rows(plan_rows)
    # if `edf_signal_index` is not present, create it before we re-order things
    plan_rows = map(enumerate(plan_rows)) do (i, row)
        edf_signal_index = coalesce(_get(row, :edf_signal_index), i)
        return rowmerge(row; edf_signal_index)
    end

    onda_signal_groupby = (REQUIRED_SIGNAL_GROUPING_COLUMNS...,
                           extra_onda_signal_groupby...)

    grouped_rows = groupby(grouper(onda_signal_groupby), plan_rows)
    sorted_keys = sort!(collect(keys(grouped_rows)))

    # generate a unique sensor label for each group based on sensor_type
    sensor_labels = Dict{Any,String}()
    sensor_counts = DefaultDict{String,Int}(0)
    for key in sorted_keys
        sensor_type = first(key)
        ismissing(sensor_type) && continue
        count = sensor_counts[sensor_type] += 1
        sensor_labels[key] = count > 1 ? string(sensor_type, '_', count) : sensor_type
    end

    output_plan_rows = []
    for key in sorted_keys
        rows = grouped_rows[key]
        sensor_label = get(sensor_labels, key, missing)
        encoding = promote_encodings(rows)
        append!(output_plan_rows,
                [rowmerge(row, encoding, (; sensor_label)) for row in rows])
    end

    return output_plan_rows
end

_get(x, property) = hasproperty(x, property) ? getproperty(x, property) : missing
function grouper(vars=REQUIRED_SIGNAL_GROUPING_COLUMNS)
    return x -> NamedTuple{vars}(_get.(Ref(x), vars))
end
grouper(vars::AbstractVector{Symbol}) = grouper((vars..., ))
grouper(var::Symbol) = grouper((var, ))

"""
    struct ConvertedSamples
        samples::Union{Samples,Missing}
        channel_plans::Vector{FilePlanV4}
        sensor_label::Union{String,Missing}
    end

Represents a group of `EDF.Signal`s which have been converted into a single `Onda.Samples`
(e.g. by [`edf_to_onda_samples`](@ref)).  The `channel_plans` are the [`FilePlanV4`s](@ref)
that were used to do the conversion.  The `sensor_label` field is the single unique value of
the `sensor_label` fields of the `channel_plans`.

If conversion failed for any reason, `samples` will be `missing`.  Any runtime errors
encountered during conversion will be stored in the `error` field of the `channel_plans`.

## Convenience functions for storing converted samples

The converted samples are _in-memory_ `Onda.Samples` objects that usually need to be
persisted to some external storage.  OndaEDF.jl implements methods for [`Onda.store`](@ref)
with a `ConvertedSamples` argument which will extract the wrapped `samples` and `Onda.store`
them.  When the wrapped `samples` are `missing`, these methods return `missing.` When the
`Onda.SignalV2`-returning method with arguments for `recording` and `start` is called, the
`sensor_label` is propagated by default (but may be overridden).

## Convenience functions for `EDF.File`-level collections

Conversion of an entire `EDF.File` via [`edf_to_onda_samples`](@ref) returns a
`Vector{ConvertedSamples}`.

The [`get_plan`](@ref) function will collate the plans for a `Vector{ConvertedSamples}` into
a single table that is suitable for passing to `Legolas.write`.

The [`get_samples`](@ref) function extracts the converted samples from a
`Vector{ConvertedSamples}`.  By default, this function will skip any samples that are
`missing`, unless called with a keyword argument `skipmissing=false`.
"""
struct ConvertedSamples
    samples::Union{Samples,Missing}
    channel_plans::Vector{FilePlanV4}
    sensor_label::Union{String,Missing}
end

"""
    get_plan(cs::AbstractVector{ConvertedSamples})

Extract the "executed plan" table from a collection of
[`ConvertedSamples`](@ref) output from [`edf_to_onda_samples`](@ref).
"""
get_plan(cs::AbstractVector{ConvertedSamples}) = reduce(vcat, c.channel_plans for c in cs)

"""
    get_samples(cs::AbstractVector{ConvertedSamples}; skipmissing=true)

Extract the `Onda.Samples` from a collection of [`ConvertedSamples`](@ref)
output from [`edf_to_onda_samples`](@ref).

If `skipmissing=true` (the default), only successfully converted samples will be
returned.  If `skipmissing=false`, then some elements may be `missing`.
"""
function get_samples(cs::AbstractVector{ConvertedSamples}; skipmissing=true)
    return if skipmissing
        [c.samples for c in cs if !ismissing(c.samples)]
    else
        [c.samples for c in cs]
    end
end

"""
    Onda.store(file_path, file_format, samples::ConvertedSamples)
    Onda.store(file_path, file_format, samples::ConvertedSamples, recording, start,
               sensor_label=samples.sensor_label)

[`ConvertedSamples`](@ref) (as output from [`edf_to_onda_samples`](@ref)) may be
stored via `Onda.store`.  If the conversion failed and the wrapped `.samples`
are `missing`, then this returns `missing`.

If a recording `UUID` and start `Period` are provided, a `Onda.SignalV2` record
will be returned pointing to the stored samples, with the `sensor_label` taken
from the converted samples.
"""
function Onda.store(file_path, file_format, samples::ConvertedSamples)
    return if ismissing(samples.samples)
        missing
    else
        Onda.store(file_path, file_format, samples.samples)
    end
end

# TODO: return a signal extension?
function Onda.store(file_path, file_format, samples::ConvertedSamples, recording, start,
                    sensor_label=samples.sensor_label)
    return if ismissing(samples.samples)
        missing
    else
        Onda.store(file_path, file_format, samples.samples, recording, start, sensor_label)
    end
end

"""
    edf_to_onda_samples(edf::EDF.File, plan_table; validate=true, dither_storage=missing)

Convert Signals found in an EDF File to `Onda.Samples` according to the plan specified in
`plan_table` (e.g., as generated by [`plan_edf_to_onda_samples`](@ref)).  Returns a
[`Vector{ConvertedSamples}`](@ref ConvertedSamples); use [`get_plan`](@ref) and
[`get_samples`](@ref) to extract the executed plan and `Onda.Samples` respectively.

The input plan is transformed by using [`merge_samples_info`](@ref) to combine
rows with the same `:sensor_label` into a common `Onda.SamplesInfo`.  Then
[`OndaEDF.onda_samples_from_edf_signals`](@ref) is used to combine the EDF
signals data into a single `Onda.Samples` per group.

Any errors that occur are shown as `String`s (with backtrace) and inserted into
the `:error` column for the corresponding rows from the plan.

Samples are returned in the order that their corresponding `:sensor_label` occurs in the
plan.  All EDF Signals from the plan with the same plan `:sensor_label` are combined into a
single `Onda.Samples`, in order of `:edf_signal_index`.  Signals that could not be matched,
where `:sensor_label` is `missing`, or otherwise caused an error during execution are not
returned.

If `validate=true` (the default), the plan is validated against the
[`FilePlanV4`](@ref) schema, and the signal headers in the `EDF.File`.

If `dither_storage=missing` (the default), dither storage is allocated automatically
as specified in the docstring for `Onda.encode`. `dither_storage=nothing` disables dithering.

$SAMPLES_ENCODED_WARNING
"""
function edf_to_onda_samples(edf::EDF.File, plan_table; validate=true, dither_storage=missing)

    true_signals = filter(x -> isa(x, EDF.Signal), edf.signals)

    if validate
        Legolas.validate(Tables.schema(Tables.columns(plan_table)),
                         OndaEDFSchemas.FilePlanV4SchemaVersion())
        for row in Tables.rows(plan_table)
            signal = true_signals[row.edf_signal_index]
            signal.header.label == row.label ||
                throw(ArgumentError("Plan's label $(row.label) does not match EDF label $(signal.header.label)!"))
        end
    end

    EDF.read!(edf)
    plan_rows = map(FilePlanV4, Tables.rows(plan_table))
    grouped_plan_rows = groupby(grouper((:sensor_label, )), plan_rows)
    converted_samples = map(collect(grouped_plan_rows)) do (key, rows)
        (; sensor_label) = key
        try
            info = merge_samples_info(rows)
            if ismissing(info)
                # merge_samples_info returns missing is any of :sensor_type,
                # :sample_unit, :sample_rate, or :channel is missing in any of
                # the rows, to indicate that it's not possible to generate
                # samples.  this keeps us from overwriting any existing, more
                # specific :errors in the plan with nonsense about promote_type
                # etc.
                samples = missing
            else
                signals = [true_signals[row.edf_signal_index] for row in rows]
                samples = onda_samples_from_edf_signals(SamplesInfoV2(info), signals,
                                                        edf.header.seconds_per_record; dither_storage)
            end
            return ConvertedSamples(samples, rows, sensor_label)
        catch e
            e isa InterruptException && rethrow()
            plan_rows = _errored_rows(rows, e)
            return ConvertedSamples(missing, plan_rows, sensor_label)
        end
    end

    return converted_samples
end

"""
    OndaEDF.merge_samples_info(plan_rows)

Create a single, merged `SamplesInfo` from plan rows, such as generated by
[`plan_edf_to_onda_samples`](@ref).  Encodings are promoted with `promote_encodings`.

The input rows must have the same values for `:sensor_type`, `:sample_unit`, and
`:sample_rate`; otherwise an `ArgumentError` is thrown.

If any of these values is `missing`, or any row's `:channel` value is `missing`,
this returns `missing` to indicate it is not possible to determine a shared
`SamplesInfo`.

The original EDF labels are included in the output in the `:edf_channels`
column.

!!! note

    This is an internal function and is not meant to be called direclty.
"""
function merge_samples_info(rows)
    # we enforce that sensor_type, sample_unit, and sample_rate are all equal here
    key = unique(map(grouper(REQUIRED_SIGNAL_GROUPING_COLUMNS), rows))
    if length(key) != 1
        throw(ArgumentError("couldn't merge samples info from rows: multiple " *
                            "sensor_type/sample_unit/sample_rate combinations:\n\n" *
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
        return (; onda_encoding..., NamedTuple(key)..., channels, edf_channels)
    end
end

"""
    OndaEDF.onda_samples_from_edf_signals(target::Onda.SamplesInfo, edf_signals,
                                          edf_seconds_per_record; dither_storage=missing)

Generate an `Onda.Samples` struct from an iterable of `EDF.Signal`s, based on
the `Onda.SamplesInfo` in `target`.  This checks for matching sample rates in
the source signals.  If the encoding of `target` is the same as the encoding in
a signal, its encoded (usually `Int16`) data is copied directly into the
`Samples` data matrix; otherwise it is re-encoded.

If `dither_storage=missing` (the default), dither storage is allocated automatically
as specified in the docstring for `Onda.encode`. `dither_storage=nothing` disables dithering.
See `Onda.encode`'s docstring for more details.

!!! note

    This function is not meant to be called directly, but through
    [`edf_to_onda_samples`](@ref)

$SAMPLES_ENCODED_WARNING
"""
function onda_samples_from_edf_signals(target::SamplesInfoV2, edf_signals,
                                       edf_seconds_per_record; dither_storage=missing)
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
            encoded_samples = try
                Onda.encode(sample_type(target), target.sample_resolution_in_unit,
                            target.sample_offset_in_unit, decoded_samples,
                            dither_storage)
             catch e
                 if e isa DomainError
                     @warn "DomainError during `Onda.encode` can be due to a dithering bug; try calling with `dither_storage=nothing` to disable dithering."
                 end
                 rethrow()
             end
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
review the plan for un-extracted signals (where `:sensor_type` or `:channel` is
`missing`) and errors (non-`nothing` values in `:error`).

Groups of `EDF.Signal`s are mapped as channels to `Onda.Samples` via
[`plan_edf_to_onda_samples`](@ref).  The caller of this function can control the
plan via the `labels` and `units` keyword arguments, all of which are forwarded
to [`plan_edf_to_onda_samples`](@ref).

`EDF.Signal` labels that are converted into Onda channel names undergo the
following transformations:

- the label is whitespace-stripped, parens-stripped, and lowercased
- trailing generic EDF references (e.g. "ref", "ref2", etc.) are dropped
- any instance of `+` is replaced with `_plus_` and `/` with `_over_`
- all component names are converted to their "canonical names" when possible
  (e.g. "3" in an ECG-matched channel name will be converted to "iii").

If more control (e.g. preprocessing signal labels) is required, callers should
use [`plan_edf_to_onda_samples`](@ref) and [`edf_to_onda_samples`](@ref)
directly, and `Onda.store` the resulting samples manually.

See the OndaEDF README for additional details regarding EDF formatting expectations.
"""
function store_edf_as_onda(edf::EDF.File, onda_dir, recording_uuid::UUID=uuid4();
                           import_annotations::Bool=true,
                           signals_prefix="edf", annotations_prefix=signals_prefix,
                           kwargs...)

    # Validate input argument early on
    signals_path = joinpath(onda_dir, "$(validate_arrow_prefix(signals_prefix)).onda.signals.arrow")
    annotations_path = joinpath(onda_dir, "$(validate_arrow_prefix(annotations_prefix)).onda.annotations.arrow")

    EDF.read!(edf)
    file_format = "lpcm.zst"

    # Trailing slash needed for compatibility with AWSS3.jl's `S3Path`
    mkpath(joinpath(onda_dir, "samples") * '/')

    # edf_samples, plan = edf_to_onda_samples(edf; kwargs...)
    converted_samples = edf_to_onda_samples(edf; kwargs...)
    plan = get_plan(converted_samples)

    errors = _get(Tables.columns(plan), :error)
    if !ismissing(errors)
        # why unique?  because errors that occur during execution get inserted
        # into all plan rows for that group of EDF signals, so they may be
        # repeated
        for e in unique(errors)
            if e !== nothing
                @warn sprint(showerror, e)
            end
        end
    end

    signals = Onda.SignalV2[]
    for (; sensor_label, samples) in converted_samples
        ismissing(samples) && continue
        sample_filename = string(recording_uuid, "_", sensor_label, ".", file_format)
        file_path = joinpath(onda_dir, "samples", sample_filename)
        signal = store(file_path, file_format, samples, recording_uuid, Second(0), sensor_label)
        push!(signals, signal)
    end

    Legolas.write(signals_path, signals, SignalV2SchemaVersion())

    if import_annotations
        annotations = edf_to_onda_annotations(edf, recording_uuid)
        if !isempty(annotations)
            Legolas.write(annotations_path, annotations,
                          OndaEDFSchemas.EDFAnnotationV1SchemaVersion())
        else
            @warn "No annotations found in $onda_dir"
            annotations_path = nothing
        end
    else
        annotations = EDFAnnotationV1[]
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

Read signals from an `EDF.File` into a [`Vector{ConvertedSamples}`](@ref ConvertedSamples).
This is a convenience function that first formulates an import plan via
[`plan_edf_to_onda_samples`](@ref), and then immediately executes this plan with
[`edf_to_onda_samples`](@ref).

!!! warning
    This function is provided as a convenience for "quick and dirty" exploration.  In
    general, it is strongly adivsed to review the plan and make any necessary adjustments
    _before_ execution.

A [`Vector{ConvertedSamples}`](@ref ConvertedSamples) is returned; use [`get_plan`](@ref)
and [`get_samples`](@ref) to extract the executed plan and `Onda.Samples` respectively.  It
is **strongly advised** that you review the output for un-extracted signals by investigating
any `ConvertedSamples` where the `.samples` are `missing`.  Run-time errors during
conversion are stored in the `:error` column of the `.channel_plans`, and any EDF Signals
that could not be matched will have `missing` values in their `.channel_plans` for
`:sensor_type`, `:channel`, or `:physical_unit`.

Collections of `EDF.Signal`s are mapped as channels to `Onda.Samples` via
[`plan_edf_to_onda_samples`](@ref).  The caller of this function can control the plan via
the `labels` and `units` keyword arguments, all of which are forwarded to
[`plan_edf_to_onda_samples`](@ref).  If more control is required, first generate the plan,
review and edit it as needed, and then execute by passing it as the second argument to
`edf_to_onda_samples`.

`EDF.Signal` labels that are converted into Onda channel names undergo the
following transformations:

- the label is whitespace-stripped, parens-stripped, and lowercased
- trailing generic EDF references (e.g. "ref", "ref2", etc.) are dropped
- any instance of `+` is replaced with `_plus_` and `/` with `_over_`
- all component names are converted to their "canonical names" when possible
  (e.g. "m1" in an EEG-matched channel name will be converted to "a1").

See the OndaEDF README for additional details regarding EDF formatting expectations.

$SAMPLES_ENCODED_WARNING
"""
function edf_to_onda_samples(edf::EDF.File; kwargs...)
    signals_plan = plan_edf_to_onda_samples(edf; kwargs...)
    EDF.read!(edf)
    return edf_to_onda_samples(edf, signals_plan)
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
    annotations = EDFAnnotationV1[]
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
                    annotation = EDFAnnotationV1(; recording=uuid, id=uuid4(),
                                                 span=TimeSpan(start_nanosecond, stop_nanosecond),
                                                 value=annotation_string)
                    push!(annotations, annotation)
                end
            end
        end
    end
    return annotations
end
