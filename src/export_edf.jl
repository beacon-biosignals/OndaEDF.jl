#####
##### Signal extrema specification
#####

struct SignalExtrema
    physical_min::Float32
    physical_max::Float32
    digital_min::Float32
    digital_max::Float32
end

SignalExtrema(samples::Samples) = SignalExtrema(samples.info)
function SignalExtrema(info::SamplesInfoV2)
    digital_extrema = (typemin(sample_type(info)), typemax(sample_type(info)))
    physical_extrema = @. (info.sample_resolution_in_unit * digital_extrema) +
                          info.sample_offset_in_unit
    return SignalExtrema(physical_extrema..., digital_extrema...)
end

#####
##### `EDF.FileHeader` conversion
#####

const DATA_RECORD_SIZE_LIMIT = 30720
const EDF_BYTE_LIMIT = 8

function edf_sample_count_per_record(samples::Samples, seconds_per_record::Float64)
    return Int32(samples.info.sample_rate * seconds_per_record)
end

_rationalize(x) = rationalize(x)
_rationalize(x::Int) = x // 1

function edf_record_metadata(all_samples::AbstractVector{<:Onda.Samples})
    sample_rates = map(s -> _rationalize(s.info.sample_rate), all_samples)
    seconds_per_record = lcm(map(denominator, sample_rates))
    samples_per_record = map(zip(all_samples, sample_rates)) do (samples, sample_rate)
        return channel_count(samples) * numerator(sample_rate) * seconds_per_record
    end
    if sum(samples_per_record) > DATA_RECORD_SIZE_LIMIT
        if length(all_samples) == 1
            seconds_per_record = Float64(inv(first(sample_rates)))
        else
            scale = gcd(numerator.(sample_rates) .* seconds_per_record)
            samples_per_record ./= scale
            sum(samples_per_record) > DATA_RECORD_SIZE_LIMIT &&
                throw(RecordSizeException(all_samples))
            seconds_per_record /= scale
        end
        sizeof(string(seconds_per_record)) > EDF_BYTE_LIMIT &&
            throw(EDFPrecisionError(seconds_per_record))
    end
    record_duration_in_nanoseconds = Nanosecond(seconds_per_record * 1_000_000_000)
    signal_duration = maximum(Onda.duration, all_samples)
    record_count = ceil(signal_duration / record_duration_in_nanoseconds)
    sizeof(string(record_count)) > EDF_BYTE_LIMIT && throw(EDFPrecisionError(record_count))
    return record_count, seconds_per_record
end

struct RecordSizeException <: Exception
    samples::Any
end

struct EDFPrecisionError <: Exception
    value::Number
end

function Base.showerror(io::IO, exception::RecordSizeException)
    print(io, "RecordSizeException: sample rates ")
    print(io, [s.info.sample_rate for s in exception.samples])
    print(io, " cannot be resolved to a data record size smaller than ")
    return print(io, DATA_RECORD_SIZE_LIMIT * 2, " bytes")
end

function Base.showerror(io::IO, exception::EDFPrecisionError)
    print(io, "EDFPrecisionError: String representation of value ")
    print(io, exception.value)
    return print(io, " is longer than 8 ASCII characters")
end

#####
##### `EDF.Signal` conversion
#####

function export_edf_label(signal_name::String, channel_name::String)
    signal_edf_name = uppercase(signal_name)
    channel_edf_name = uppercase(channel_name)
    if signal_edf_name == "EEG" && !('-' in channel_edf_name)
        channel_edf_name *= "-Ref"
    end
    return string(signal_edf_name, " ", channel_edf_name)
end

function onda_samples_to_edf_header(samples::AbstractVector{<:Samples};
                                    version::AbstractString="0",
                                    patient_metadata=EDF.PatientID(missing, missing,
                                                                   missing, missing),
                                    recording_metadata=EDF.RecordingID(missing, missing,
                                                                       missing, missing),
                                    is_contiguous::Bool=true,
                                    start::DateTime=DateTime(Year(1985)))
    return EDF.FileHeader(version, patient_metadata, recording_metadata, start,
                          is_contiguous, edf_record_metadata(samples)...)
end

"""
    reencode_samples(samples::Samples, sample_type::Type{<:Integer}=Int16)

Encode `samples` so that they can be stored as `sample_type`.  The default
`sample_type` is `Int16` which is the target for EDF format.  The returned
`Samples` will be encoded, with a `info.sample_type` that is either equal to
`sample_type` or losslessly `convert`ible.

If the `info.sample_type` of the input samples cannot be losslessly converted to
`sample_type`, new quantization settings are chosen based on the actual signal
extrema, choosing a resolution/offset that maps them to `typemin(sample_type),
typemax(sample_type)`.

Returns an encoded `Samples`, possibly with updated `info`.  If the current
encoded values can be represented with `sample_type`, the `.info` is not changed.  If
they cannot, the `sample_type`, `sample_resolution_in_unit`, and
`sample_offset_in_unit` fields are changed to reflect the new encoding.
"""
function reencode_samples(samples::Samples, sample_type::Type{<:Integer}=Int16)
    # if we can fit the encoded values in `sample_type` without any changes,
    # return as-is.
    #
    # first, check at the type level since this is cheap and doesn't require
    # re-encoding possibly decoded values
    current_type = Onda.sample_type(samples.info)
    typemin(current_type) >= typemin(sample_type) &&
        typemax(current_type) <= typemax(sample_type) &&
        return encode(samples)

    # next, check whether the encoded values are <: Integers that lie within the
    # range representable by `sample_type` and can be converted directly.
    if Onda.sample_type(samples.info) <: Integer
        smin, smax = extrema(samples.data)
        if !samples.encoded
            smin, smax = Onda.encode_sample.(Onda.sample_type(samples.info),
                                             samples.info.sample_resolution_in_unit,
                                             samples.info.sample_offset_in_unit,
                                             (smin, smax))
            # make sure we handle negative resolutions properly!
            smin, smax = extrema((smin, smax))
        end
        if smin >= typemin(sample_type) && smax <= typemax(sample_type)
            # XXX: we're being a bit clever here in order to not allocate a
            # whole new sample array, plugging in the new sample_type, re-using
            # the old encoded samples data, and skipping validation.  this is
            # okay in _this specific context_ since we know we're actually
            # converting everything to sample_type in the actual export.
            samples = encode(samples)
            new_info = SamplesInfoV2(Tables.rowmerge(samples.info; sample_type))
            return Samples(samples.data, new_info, true; validate=false)
        end
    end

    # at this point, we know the currently _encoded_ values cannot be
    # represented losslessly as sample_type, so we need to re-encode.  We'll pick new
    # encoding parameters based on the actual signal values, in order to
    # maximize the dynamic range of Int16 encoding.
    samples = decode(samples)
    smin, smax = extrema(samples.data)
    # If the input is flat, normalize max to min + 1
    if smin == smax
        smax = smin + one(smax)
    end

    emin, emax = typemin(sample_type), typemax(sample_type)

    # re-use the import encoding calculator here:
    # need to convert all the min/max to floats due to possible overflow
    mock_header = (; digital_minimum=Float64(emin), digital_maximum=Float64(emax),
                   physical_minimum=Float64(smin), physical_maximum=Float64(smax),
                   samples_per_record=0) # not using this

    donor_info = edf_signal_encoding(mock_header, 1)
    sample_resolution_in_unit = donor_info.sample_resolution_in_unit
    sample_offset_in_unit = donor_info.sample_offset_in_unit

    new_info = Tables.rowmerge(samples.info;
                               sample_resolution_in_unit,
                               sample_offset_in_unit,
                               sample_type)

    new_samples = Samples(samples.data, SamplesInfoV2(new_info), samples.encoded)
    return encode(new_samples)
end

function onda_samples_to_edf_signals(onda_samples::AbstractVector{<:Samples},
                                     seconds_per_record::Float64)
    edf_signals = Union{EDF.AnnotationsSignal,EDF.Signal{Int16}}[]
    for samples in onda_samples
        # encode samples, rescaling if necessary
        samples = reencode_samples(samples, Int16)
        signal_name = samples.info.sensor_type
        extrema = SignalExtrema(samples)
        for channel_name in samples.info.channels
            sample_count = edf_sample_count_per_record(samples, seconds_per_record)
            physical_dimension = onda_to_edf_unit(samples.info.sample_unit)
            edf_signal_header = EDF.SignalHeader(export_edf_label(signal_name,
                                                                  channel_name),
                                                 "", physical_dimension,
                                                 extrema.physical_min, extrema.physical_max,
                                                 extrema.digital_min, extrema.digital_max,
                                                 "", sample_count)
            # manually convert here in case we have input samples whose encoded
            # values are convertible losslessly to Int16:
            sample_data = Int16.(vec(samples[channel_name, :].data))
            padding = Iterators.repeated(zero(Int16),
                                         (sample_count -
                                          (length(sample_data) % sample_count)) %
                                         sample_count)
            edf_signal_samples = append!(sample_data, padding)
            push!(edf_signals, EDF.Signal(edf_signal_header, edf_signal_samples))
        end
    end
    return edf_signals
end

#####
##### `export_edf`
#####

"""
    onda_to_edf(samples::AbstractVector{<:Samples}, annotations=[]; kwargs...)

Return an `EDF.File` containing signal data converted from a collection of Onda
[`Samples`](https://beacon-biosignals.github.io/Onda.jl/stable/#Samples-1) and
(optionally) annotations from an [`annotations`
table](https://beacon-biosignals.github.io/Onda.jl/stable/#*.onda.annotations.arrow-1).

Following the Onda v0.5 format, `annotations` can be any Tables.jl-compatible
table (DataFrame, Arrow.Table, NamedTuple of vectors, vector of NamedTuples)
which follows the [annotation
schema](https://beacon-biosignals.github.io/Onda.jl/stable/#*.onda.annotations.arrow-1).

Each `EDF.Signal` in the returned `EDF.File` corresponds to a channel of an
input `Onda.Samples`.

The ordering of `EDF.Signal`s in the output will match the order of the input
collection of `Samples` (and within each channel grouping, the order of the
samples' channels).

!!! note

    EDF signals are encoded as Int16, while Onda allows a range of different
    sample types, some of which provide considerably more resolution than Int16.
    During export, re-encoding may be necessary if the encoded Onda samples
    cannot be represented directly as Int16 values.  In this case, new encoding
    (resolution and offset) will be chosen based on the minimum and maximum
    values actually present in each _signal_ in the input Onda Samples.  Thus,
    it may not always be possible to losslessly round trip Onda-formatted
    datasets to EDF and back.

"""
function onda_to_edf(samples::AbstractVector{<:Samples}, annotations=[]; kwargs...)
    edf_header = onda_samples_to_edf_header(samples; kwargs...)
    edf_signals = onda_samples_to_edf_signals(samples, edf_header.seconds_per_record)
    if !isempty(annotations)
        records = [[EDF.TimestampedAnnotationList(edf_header.seconds_per_record * i,
                                                  nothing, String[""])]
                   for i in 0:(edf_header.record_count - 1)]
        for annotation in sort(Tables.rowtable(annotations); by=row -> start(row.span))
            annotation_onset_in_seconds = start(annotation.span).value / 1e9
            annotation_duration_in_seconds = duration(annotation.span).value / 1e9
            matching_record = records[Int(fld(annotation_onset_in_seconds, edf_header.seconds_per_record)) + 1]
            tal = EDF.TimestampedAnnotationList(annotation_onset_in_seconds,
                                                annotation_duration_in_seconds,
                                                [annotation.value])
            push!(matching_record, tal)
        end
        push!(edf_signals, EDF.AnnotationsSignal(records))
    end
    return EDF.File((io=IOBuffer(); close(io); io), edf_header, edf_signals)
end
