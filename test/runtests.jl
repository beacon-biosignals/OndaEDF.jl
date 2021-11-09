using Test, Dates, Random, UUIDs, Statistics
using OndaEDF, Onda, EDF, Tables
using FilePathsBase: AbstractPath, PosixPath

function test_edf_signal(rng, label, transducer, physical_units,
                         physical_min, physical_max,
                         digital_min, digital_max,
                         samples_per_record, n_records)
    header = EDF.SignalHeader(label, transducer, physical_units,
                              physical_min, physical_max,
                              digital_min, digital_max,
                              "", Int16(samples_per_record))
    samples = rand(rng, Int16, n_records * samples_per_record)
    return EDF.Signal(header, samples)
end

function make_test_data(rng, sample_rate, samples_per_record, n_records)
    imin16, imax16 = Float32(typemin(Int16)), Float32(typemax(Int16))
    anns_1 = [[EDF.TimestampedAnnotationList(i, nothing, []),
               EDF.TimestampedAnnotationList(i, i + 1, ["", "$i a", "$i b"])] for i in 1:n_records]
    anns_2 = [[EDF.TimestampedAnnotationList(i, nothing, []),
               EDF.TimestampedAnnotationList(i, 0, ["", "$i c", "$i d"])] for i in 1:n_records]
    edf_signals = Union{EDF.AnnotationsSignal,EDF.Signal}[
        test_edf_signal(rng, "EEG F3-M2", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EEG F4-M1", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EEG C3-M2", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EEG O1-M2", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "C4-M1", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "O2-A1", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "E1", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "E2", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "Fpz",   "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        EDF.AnnotationsSignal(samples_per_record, anns_1)
        test_edf_signal(rng, "EMG LAT",   "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EMG RAT",   "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "SNORE", "E", "uV",  -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "IPAP", "", "cmH2O", -74.0465f0, 74.19587f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EPAP", "", "cmH2O", -73.5019f0, 74.01962f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "CFLOW", "",  "LPM", -309.153f0, 308.8513f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "PTAF", "",     "v", -125.009f0, 125.009f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "Leak", "",   "LPM", -147.951f0, 148.4674f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "CHEST", "E",  "uV", -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "ABD", "E",    "uV", -32768.0f0, 32767.0f0,   imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "Tidal", "",   "mL", -4928.18f0, 4906.871f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "SaO2", "",    "%",       0.0f0,    100.0f0,  imin16, imax16, samples_per_record, n_records)
        EDF.AnnotationsSignal(samples_per_record, anns_2)
        test_edf_signal(rng, "EKG EKGR- REF", "E",  "uV",   -9324.0f0, 2034.0f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "IC", "E",    "uV",    -32768.0f0, 32767.0f0, imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "HR", "",    "BpM",    -32768.0f0, 32768.0f0, imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "EcG EKGL", "E",  "uV",   -10932.0f0, 1123.0f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "- REF", "E",  "uV",   -10932.0f0, 1123.0f0,  imin16, imax16, samples_per_record, n_records)
        test_edf_signal(rng, "REF1", "E",  "uV",   -10932.0f0, 1123.0f0,  imin16, imax16, samples_per_record, n_records)
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

include("test_edf_to_samples_info.in")

@testset "OndaEDF" begin
    include("signal_labels.jl")
    include("import.jl")
    include("export.jl")
end

@info """
    To look for the effect of any modifications made to OndaEDF, look at:
    `diff test/test_edf_to_samples_info.{in,out}`
"""
