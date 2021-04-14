#####
##### Signal extrema specification
#####

struct SignalExtrema
    physical_min::Float32
    physical_max::Float32
    digital_min::Float32
    digital_max::Float32
end

SignalExtrema(signal) = SignalExtrema(SamplesInfo(signal))
function SignalExtrema(info::SamplesInfo)
    digital_extrema = (typemin(info.sample_type), typemax(info.sample_type))
    physical_extrema = @. (info.sample_resolution_in_unit * digital_extrema) + info.sample_offset_in_unit
    return SignalExtrema(physical_extrema..., digital_extrema...)
end

#####
##### `EDF.FileHeader` conversion
#####

const DATA_RECORD_SIZE_LIMIT = 30720
const EDF_BYTE_LIMIT = 8

edf_sample_count_per_record(signal, seconds_per_record::Float64) = Int16(signal.sample_rate * seconds_per_record)

function edf_record_metadata(signals)
    sample_rates = map(signal -> rationalize(signal.sample_rate), signals)
    seconds_per_record = lcm(map(denominator, sample_rates))
    samples_per_record = map(zip(signals, sample_rates)) do (signal, sample_rate)
        return channel_count(signal) * numerator(sample_rate) * seconds_per_record
    end
    if sum(samples_per_record) > DATA_RECORD_SIZE_LIMIT
        if length(signals) == 1
            seconds_per_record = Float64(inv(first(sample_rates)))
        else
            scale = gcd(numerator.(sample_rates) .* seconds_per_record)
            samples_per_record ./= scale
            sum(samples_per_record) > DATA_RECORD_SIZE_LIMIT && throw(RecordSizeException(signals))
            seconds_per_record /= scale
        end
        sizeof(string(seconds_per_record)) > EDF_BYTE_LIMIT && throw(EDFPrecisionError(seconds_per_record))
    end
    record_duration_in_nanoseconds = Nanosecond(seconds_per_record * 1_000_000_000)
    signal_duration = maximum(signal -> stop(signal.span), signals)
    record_count = ceil(signal_duration / record_duration_in_nanoseconds)
    sizeof(string(record_count)) > EDF_BYTE_LIMIT && throw(EDFPrecisionError(record_count))
    return record_count, seconds_per_record
end

struct RecordSizeException <: Exception
    signals::Vector{Onda.Signal}
end

struct EDFPrecisionError <: Exception
    value::Number
end

function Base.showerror(io::IO, exception::RecordSizeException)
    print(io, "RecordSizeException: sample rates ")
    print(io, [signal.sample_rate for signal in exception.signals])
    print(io, " cannot be resolved to a data record size smaller than ")
    print(io, DATA_RECORD_SIZE_LIMIT * 2, " bytes")
end

function Base.showerror(io::IO, exception::EDFPrecisionError)
    print(io, "EDFPrecisionError: String representation of value ")
    print(io, exception.value)
    print(io, " is longer than 8 ASCII characters")
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

function export_edf_header(signals;
                           version::AbstractString="0",
                           patient_metadata=EDF.PatientID(missing, missing, missing, missing),
                           recording_metadata=EDF.RecordingID(missing, missing, missing, missing),
                           is_contiguous::Bool=true,
                           start::DateTime=DateTime(Year(1985)))
    return EDF.FileHeader(version, patient_metadata, recording_metadata, start,
                          is_contiguous, edf_record_metadata(signals)...)
end



function export_edf_signals(signals, seconds_per_record::Float64)
    edf_signals = Union{EDF.AnnotationsSignal,EDF.Signal}[]
    for onda_signal in signals
        signal_name = onda_signal.kind
        # parse the strings in the signals row
        samples_info = SamplesInfo(onda_signal)
        if sizeof(samples_info.sample_type) > sizeof(Int16)
            decoded_samples = Onda.load(onda_signal; encoded=false)
            scaled_resolution = samples_info.sample_resolution_in_unit * (sizeof(samples_info.sample_type) / sizeof(Int16))
            signal = Tables.rowmerge(onda_signal; sample_type=Int16, sample_resolution_in_unit=scaled_resolution)
            samples = encode(Onda.Samples(decoded_samples.data, SamplesInfo(signal), false))
        else
            signal = onda_signal
            samples = Onda.load(onda_signal; encoded=true)
        end
        extrema = SignalExtrema(signal)
        for channel_name in onda_signal.channels
            sample_count = edf_sample_count_per_record(onda_signal, seconds_per_record)
            physical_dimension = onda_to_edf_unit(onda_signal.sample_unit)
            edf_signal_header = EDF.SignalHeader(export_edf_label(signal_name, channel_name),
                                                 "", physical_dimension,
                                                 extrema.physical_min, extrema.physical_max,
                                                 extrema.digital_min, extrema.digital_max,
                                                 "", sample_count)
            sample_data = vec(samples[channel_name, :].data)
            padding = Iterators.repeated(zero(Int16), (sample_count - (length(sample_data) % sample_count)) % sample_count)
            edf_signal_samples = append!(sample_data, padding)
            push!(edf_signals, EDF.Signal(edf_signal_header, edf_signal_samples))
        end
    end
    return edf_signals
end

######
###### `export_edf`
######

"""
   export_edf(signals, annotations=[]; kwargs...)

Return an `EDF.File` containing signal data converted from the Onda [`signals`
table](https://beacon-biosignals.github.io/Onda.jl/stable/#*.onda.signals.arrow-1)
and (optionally) annotations from an [`annotations`
table](https://beacon-biosignals.github.io/Onda.jl/stable/#*.onda.annotations.arrow-1).

Following the Onda v0.5 format, both `signals` and `annotations` can be any
Tables.jl-compatible table (DataFrame, Arrow.Table, NamedTuple of vectors, vector of
NamedTuples) which follow the signal and annotation schemas (respectively).

Each `EDF.Signal` in the returned `EDF.File` corresponds to a channel of an `Onda.Signal`;

The ordering of `EDF.Signal`s in the output will match the order of the rows of
the signals table (and within each channel grouping, the order of the signal's
channels).
"""
function export_edf(signals, annotations=[]; kwargs...)
    edf_header = export_edf_header(signals; kwargs...)
    edf_signals = export_edf_signals(signals, edf_header.seconds_per_record)
    if !isempty(annotations)
        records = [[EDF.TimestampedAnnotationList(edf_header.seconds_per_record * i, nothing, String[""])]
                   for i in 0:(edf_header.record_count - 1)]
        for annotation in sort(Tables.rows(annotations); by=row -> start(row.span))
            annotation_onset_in_seconds = start(annotation.span).value / 1e9
            annotation_duration_in_seconds = duration(annotation.span).value / 1e9
            matching_record = records[Int(fld(annotation_onset_in_seconds, edf_header.seconds_per_record)) + 1]
            tal = EDF.TimestampedAnnotationList(annotation_onset_in_seconds, annotation_duration_in_seconds, [annotation.value])
            push!(matching_record, tal)
        end
        push!(edf_signals, EDF.AnnotationsSignal(records))
    end
    return EDF.File((io = IOBuffer(); close(io); io), edf_header, edf_signals)
end
