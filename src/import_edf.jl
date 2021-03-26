#####
##### `EDF.Signal` label handling
#####

function edf_type_and_spec(label::AbstractString)
    parsed = split(label; limit=2, keepempty=false)
    if length(parsed) == 2
        type = replace(parsed[1], r"\s"=>"")
        spec = replace(parsed[2], r"\s"=>"")
    else
        # if no clear specification is present, the whole label
        # is just considered the "type" by the EDF+ standard
        type = replace(label, r"\s"=>"")
        spec = nothing
    end
    return type, spec
end

# This function:
# - ensures the given label is whitespace-stripped, lowercase, and parens-free
# - strips trailing generic EDF references (e.g. "ref", "ref2", etc.)
# - replaces all references with the appropriate name as specified by `canonical_names`
# - replaces `+` with `_plus_` and `/` with `_over_`
# - returns the initial reference name (w/o prefix sign, if present) and the entire label
function _normalize_references(original_label, canonical_names)
    label = replace(lowercase(original_label), r"\s"=>"")
    label = replace(replace(label, '('=>""), ')'=>"")
    label = replace(label, '-'=>'…')
    label = replace(label, '+'=>"…+…")
    label = replace(label, '/'=>"…/…")
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

function match_edf_label(label, signal_names, channel_name, canonical_names)
    type, spec = edf_type_and_spec(lowercase(label))
    if spec === nothing
        label = type
    else
        any(==(type), signal_names) || return nothing
        label = spec
    end
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
    extracted_channel_names = String[]
    extracted_channels = EDF.Signal[]
    for channel_matcher in channel_matchers
        for edf_signal in edf_signals
            edf_signal isa EDF.Signal || continue
            any(x -> x === edf_signal, extracted_channels) && continue
            channel_name = channel_matcher(edf_signal)
            channel_name === nothing && continue
            push!(extracted_channel_names, channel_name)
            push!(extracted_channels, edf_signal)
        end
    end
    return extracted_channel_names, extracted_channels
end

function extract_channels_by_label(edf::EDF.File, signal_names, channel_names)
    matcher = x -> begin
        # yo I heard you like closures
        return s -> match_edf_label(s.header.label, signal_names,
                                    x isa Pair ? first(x) : x,
                                    channel_names)
    end
    edf_channel_names, edf_channels = extract_channels(edf.signals, (matcher(x) for x in channel_names))
    isempty(edf_channel_names) && return nothing
    edf_encodings = map(s -> edf_signal_encoding(s.header, edf.header.seconds_per_record), edf_channels)
    onda_units = map(s -> edf_to_onda_unit(s.header.physical_dimension), edf_channels)
    onda_sample_unit = first(onda_units)
    all(==(onda_sample_unit), onda_units) || error("multiple possible units found for same signal: $onda_units")
    onda_encoding = promote_encodings(edf_encodings)
    onda_stop_nanosecond = Onda.time_from_index(onda_encoding.sample_rate, length(edf_channels[1].samples) + 1)

    info = SamplesInfo(; kind=first(signal_names), channels=edf_channel_names,
                       sample_unit=string(onda_sample_unit),
                       sample_resolution_in_unit=onda_encoding.sample_resolution_in_unit,
                       sample_offset_in_unit=onda_encoding.sample_offset_in_unit,
                       sample_type=onda_encoding.sample_type,
                       sample_rate=onda_encoding.sample_rate)

    #onda_signal = Onda.Signal(channel_names=edf_channel_names,
    #                          sample_type=onda_encoding.sample_type,
    #                          sample_rate=onda_encoding.sample_rate,
    #                          sample_offset_in_unit=onda_encoding.sample_offset_in_unit,
    #                          sample_resolution_in_unit=onda_encoding.sample_resolution_in_unit,
    #                          sample_unit=onda_sample_unit,
    #                          start_nanosecond=Nanosecond(0),
    #                          stop_nanosecond=onda_stop_nanosecond,
    #                          file_extension=Symbol("lpcm.zst"),
    #                          file_options=nothing)
    return info, edf_channels
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
    import_edf!(path, edf::EDF.File, uuid::UUID=uuid4();
                custom_extractors=(), import_annotations::Bool=true)

Create, store, and return a `uuid::UUID => recording::Onda.Recording` where all
the signals in `recording` are converted from the provided `edf`. Collections
of `EDF.Signal`s are mapped as channels to `Onda.Signal`s via simple "extractor"
callbacks of the form:

    edf::EDF.File -> (onda_signal_name::Symbol,
                      onda_signal::Onda.Signal,
                      edf_signals::Vector{EDF.Signal})

`import_edf!` automatically uses a variety of default extractors derived from
the EDF standard texts; see `src/standards.jl` for details. The caller can also
provide additional extractors via the `custom_extractors` keyword argument.

`EDF.Signal` labels that are converted into Onda channel names undergo the
following transformations:

- the label is whitespace-stripped, parens-stripped, and lowercased
- trailing generic EDF references (e.g. "ref", "ref2", etc.) are dropped
- any instance of `+` is replaced with `_plus_` and `/` with `_over_`
- all component names are converted to their "canonical names" when possible
  (e.g. "m1" in an EEG-matched channel name will be converted to "a1").

If `import_annotations` is `true`, any EDF+ annotations in `edf` will be written
out as Onda annotations to `recording`.

See the OndaEDF README for additional details regarding EDF formatting expectations.
"""
function import_edf!(path, edf::EDF.File, uuid::UUID=uuid4();
                     custom_extractors=(), import_annotations::Bool=true)
    EDF.read!(edf)
    file_format = "lpcm.zst"
    signals = Signal[]
    for extractor in Iterators.flatten((STANDARD_EXTRACTORS, custom_extractors))
        extracted = extractor(edf)
        extracted === nothing && continue
        samples_info, edf_signals = extracted
        file_path = joinpath(path, "samples", string(uuid, "_", samples_info.kind, ".", file_format))
        samples = onda_samples_from_edf_signals(samples_info, edf_signals, edf.header.seconds_per_record)
        signal = store(file_path, file_format, samples, uuid, Second(0))
        push!(signals, signal)
    end
    signals_path = joinpath(path, "onda.signals.arrow")
    write_signals(signals_path, signals)
    if import_annotations
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
        annotations_path = joinpath(path, "onda.annotations.arrow")
        write_annotations(annotations_path, annotations)
    end
    return uuid => (signals, annotations)
end
