using Test, Dates, Random, UUIDs, Statistics
using OndaEDF, Onda, EDF, Tables
using FilePathsBase: AbstractPath, PosixPath

function test_edf_signal(rng, label, transducer, physical_units,
                         physical_min, physical_max,
                         digital_min, digital_max,
                         samples_per_record, n_records, ::Type{T}=Int16) where {T}
    header = EDF.SignalHeader(label, transducer, physical_units,
                              physical_min, physical_max,
                              digital_min, digital_max,
                              "", convert(T, samples_per_record))
    samples = rand(rng, T, n_records * samples_per_record)
    return EDF.Signal(header, samples)
end

function make_test_data(rng, sample_rate, samples_per_record, n_records, ::Type{T}=Int16) where {T}
    imin16, imax16 = Float32(typemin(T)), Float32(typemax(T))
    anns_1 = [[EDF.TimestampedAnnotationList(i, nothing, []),
               EDF.TimestampedAnnotationList(i, i + 1, ["", "$i a", "$i b"])] for i in 1:n_records]
    anns_2 = [[EDF.TimestampedAnnotationList(i, nothing, []),
               EDF.TimestampedAnnotationList(i, 0, ["", "$i c", "$i d"])] for i in 1:n_records]
    _edf_signal = (label, transducer, unit, lo, hi) -> test_edf_signal(rng, label, transducer, unit, lo, hi, imin16,
                                                                       imax16, samples_per_record, n_records, T)
    edf_signals = Union{EDF.AnnotationsSignal,EDF.Signal{T}}[
        _edf_signal("EEG F3-M2", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("EEG F4-M1", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("EEG C3-M2", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("EEG O1-M2", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("C4-M1", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("O2-A1", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("E1", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("E2", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("Fpz", "E", "uV", -32768.0f0, 32767.0f0),
        EDF.AnnotationsSignal(samples_per_record, anns_1),
        _edf_signal("EMG LAT", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("EMG RAT", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("SNORE", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("IPAP", "", "cmH2O", -74.0465f0, 74.19587f0),
        _edf_signal("EPAP", "", "cmH2O", -73.5019f0, 74.01962f0),
        _edf_signal("CFLOW", "", "LPM", -309.153f0, 308.8513f0),
        _edf_signal("PTAF", "", "v", -125.009f0, 125.009f0),
        _edf_signal("Leak", "", "LPM", -147.951f0, 148.4674f0),
        _edf_signal("CHEST", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("ABD", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("Tidal", "", "mL", -4928.18f0, 4906.871f0),
        _edf_signal("SaO2", "", "%", 0.0f0, 100.0f0),
        EDF.AnnotationsSignal(samples_per_record, anns_2),
        _edf_signal("EKG EKGR- REF", "E", "uV", -9324.0f0, 2034.0f0),
        _edf_signal("IC", "E", "uV", -32768.0f0, 32767.0f0),
        _edf_signal("HR", "", "BpM", -32768.0f0, 32768.0f0),
        _edf_signal("EcG EKGL", "E", "uV", -10932.0f0, 1123.0f0),
        _edf_signal("- REF", "E", "uV", -10932.0f0, 1123.0f0),
        _edf_signal("REF1", "E", "uV", -10932.0f0, 1123.0f0),
    ]
    seconds_per_record = samples_per_record / sample_rate
    edf_header = EDF.FileHeader("0", "", "", DateTime("2014-10-27T22:24:28"), true, n_records, seconds_per_record)
    edf = EDF.File((io = IOBuffer(); close(io); io), edf_header, edf_signals)
    return edf, Dict(:eeg => [9, 1, 2, 3, 5, 4, 6],
                     :eog => [7, 8],
                     :ecg => [27, 24],
                     :emg => [25, 11, 12],
                     :heart_rate => [26],
                     :tidal_volume => [21],
                     :respiratory_effort => [19, 20],
                     :snore => [13],
                     :positive_airway_pressure => [14, 15],
                     :pap_device_leak => [18],
                     :pap_device_cflow => [16],
                     :sao2 => [22],
                     :ptaf => [17])
end

@testset "OndaEDF" begin
    include("signal_labels.jl")
    include("import.jl")
    include("export.jl")
end
