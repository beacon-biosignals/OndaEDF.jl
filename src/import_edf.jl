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
    label = !isnothing(match(r"^\[.*\]$", label)) ? label[2:end-1] : label
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
    return (sample_resolution_in_unit=Float64(sample_resolution_in_unit),
            sample_offset_in_unit=Float64(sample_offset_in_unit),
            sample_rate=Float64(sample_rate))
end

# TODO: implement a more disciplined widening protocol for `sample_type`
function promote_encodings(encodings; pick_offset=(_ -> 0.0), pick_resolution=minimum)
    sample_type = Int16

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
            any(x -> x === edf_signal, map(last, extracted_channels)) && continue
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

function groupby(f, list)
    d = Dict()
    for v in list
        push!(get!(d, f(v), Vector{eltype(list)}()), v)
    end
    return d
end

"""
    extract_channels_by_label(edf::EDF.File, signal_names, channel_names)

For one or more signal names and one or more channel names,
return a list of `[(infos, errors)...]` where `errors` is a vector of errors that occurred,
and `infos` is a vector of `(si::Onda.SamplesInfo, edf_signals::Vector{EDF.Signal})`,
where `edf_signals` align with `si.channel`. This list can have more than one pair
if channels with the same signal kind/type have different sample rates or
physical units.

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
function extract_channels_by_label(edf::EDF.File, signal_names, channel_names; unit_alternatives=STANDARD_UNITS, preprocess_labels=(l,t) -> l)
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

#####
##### `import_edf!`
#####

function onda_samples_from_edf_signals(target::Onda.SamplesInfo, edf_signals,
                                       edf_seconds_per_record)
    sample_count = length(first(edf_signals).samples)
    if !all(length(s.samples) == sample_count for s in edf_signals)
        error("mismatched sample counts between `EDF.Signal`s: ", [length(s.samples) for s in edf_signals])
    end
    sample_data = Matrix{target.sample_type}(undef, length(target.channels), sample_count)
    for (i, edf_signal) in enumerate(edf_signals)
        edf_encoding = edf_signal_encoding(edf_signal.header, edf_seconds_per_record)
        if target.sample_rate != edf_encoding.sample_rate
            throw(MismatchedSampleRateError((target.sample_rate, edf_encoding.sample_rate)))
        end
        if (target.sample_resolution_in_unit != edf_encoding.sample_resolution_in_unit ||
            target.sample_offset_in_unit != edf_encoding.sample_offset_in_unit ||
            target.sample_type != eltype(edf_signal.samples))
            decoded_samples = Onda.decode(edf_encoding.sample_resolution_in_unit,
                                          edf_encoding.sample_offset_in_unit,
                                          edf_signal.samples)
            encoded_samples = Onda.encode(target.sample_type, target.sample_resolution_in_unit,
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
    store_edf_as_onda(path, edf::EDF.File, uuid::UUID=uuid4();
                      custom_extractors=STANDARD_EXTRACTORS, import_annotations::Bool=true,
                      signals_prefix="edf", annotations_prefix=signals_prefix)

Convert an EDF.File to `Onda.Samples` and `Onda.Annotation`s, store the samples
in `\$path/samples/`, and write the Onda signals and annotations tables to
`\$path/\$(signals_prefix).onda.signals.arrow` and
`\$path/\$(annotations_prefix).onda.annotations.arrow`.  The default prefix is
"edf", and if a prefix is provided for signals but not annotations both will use
the signals prefix.  The prefixes cannot reference (sub)directories.

Returns `uuid => (signals, annotations)`.

Samples are extracted with [`edf_to_onda_samples`](@ref), and EDF+ annotations are
extracted with [`edf_to_onda_annotations`](@ref) if `import_annotations==true`
(the default).

Collections of `EDF.Signal`s are mapped as channels to `Onda.Signal`s via simple
"extractor" callbacks of the form:

    edf::EDF.File -> (samples_info::Onda.SamplesInfo,
                      edf_signals::Vector{EDF.Signal})

`store_edf_as_onda` automatically uses a variety of default extractors derived
from the EDF standard texts; see `src/standards.jl` and
[`extract_channels_by_label`](@ref) for details. The caller can also provide
additional extractors via the `custom_extractors` keyword argument, and the
[`edf_signals_to_samplesinfo`](@ref) utility can be used to extract a common
`Onda.SamplesInfo` from a collection of EDF.Signals.

`EDF.Signal` labels that are converted into Onda channel names undergo the
following transformations:

- the label is whitespace-stripped, parens-stripped, and lowercased
- trailing generic EDF references (e.g. "ref", "ref2", etc.) are dropped
- any instance of `+` is replaced with `_plus_` and `/` with `_over_`
- all component names are converted to their "canonical names" when possible
  (e.g. for an EOG matched channel, "eogl", "loc", "lefteye", etc. are converted
  to "left").

See the OndaEDF README for additional details regarding EDF formatting expectations.
"""
function store_edf_as_onda(path, edf::EDF.File, uuid::UUID=uuid4();
                           custom_extractors=STANDARD_EXTRACTORS, import_annotations::Bool=true,
                           signals_prefix="edf", annotations_prefix=signals_prefix)
    EDF.read!(edf)
    file_format = "lpcm.zst"

    signals = Any[]
    edf_samples, nt = edf_to_onda_samples(edf; custom_extractors=custom_extractors)
    for error in nt.errors
        if isa(e, SamplesInfoError)
            @warn e.msg exception=e.cause
        elseif isa(e, AmbiguousChannelError)
            @warn e.summary exception=e
        else
            @warn exception=e
        end
    end
    for samples in edf_samples
        file_path = joinpath(path, "samples", string(uuid, "_", samples.info.kind, ".", file_format))
        signal = rowmerge(store(file_path, file_format, samples, uuid, Second(0)); file_path=string(file_path))
        push!(signals, signal)
    end

    signals_path = joinpath(path, "$(validate_arrow_prefix(signals_prefix)).onda.signals.arrow")
    write_signals(signals_path, signals)
    if import_annotations
        annotations = edf_to_onda_annotations(edf, uuid)
        if !isempty(annotations)
            annotations_path = joinpath(path, "$(validate_arrow_prefix(annotations_prefix)).onda.annotations.arrow")
            write_annotations(annotations_path, annotations)
        else
            @warn "No annotations found in $path"
        end
    else
        annotations = Annotation[]                                    
    end
    return uuid => (signals, annotations)
end

function validate_arrow_prefix(prefix)
    prefix == basename(prefix) || throw(ArgumentError("prefix \"$prefix\" is invalid: cannot contain directory separator"))
    pm = match(r"(.*).onda.(signals|annotations).arrow", prefix)
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
        errors = sort(errors; by=string)
        matched, errors
    catch e
        [], [e]
    end
    matched_edf_headers = reduce(∪, last.(info_map); init=[])
    unextracted = [s.header for s in edf.signals if isa(s, EDF.Signal) && s ∉ matched_edf_headers]
    header_map = [info => [s.header for s in edf_signals if isa(s, EDF.Signal)] for (info, edf_signals) in info_map]
    return info_map, (header_map=header_map,
                      unextracted_edf_headers=unextracted,
                      errors=errors)
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
                    annotation = Annotation(uuid, uuid4(), TimeSpan(start_nanosecond, stop_nanosecond);
                                            value=annotation_string)
                    push!(annotations, annotation)
                end
            end
        end
    end
    return annotations
end
