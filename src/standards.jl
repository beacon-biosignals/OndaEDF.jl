# https://www.edfplus.info/specs/edftexts.html

# This is a mapping from Onda-appropriate unit names to EDF standard physical dimensions.
# This doesn't cover everything, just units that we've seen often. Note that casing
# matters for the EDF standard physical dimensions, so we can't just always normalize
# to a single case when processing; this results in some redundant-looking values below.
const STANDARD_UNITS = Dict(:nanovolt => ["nV"],
                            :microvolt => ["uV"],
                            :millivolt => ["mV"],
                            :centivolt => ["cV"],
                            :decivolt => ["dV"],
                            :volt => ["V", "v"],
                            :millimiter => ["mm"],
                            :centimeter => ["cm"],
                            :milliliter => ["mL", "ml"],
                            :degrees_celsius => ["degC", "degc"],
                            :degrees_fahrenheit => ["degF", "degf"],
                            :kelvin => ["K"],
                            :percent => ["%"],
                            :liter_per_minute => ["L/m", "l/m", "LPM", "Lpm", "lpm", "LpM"],
                            :millimeter_of_mercury => ["mmHg", "mmhg", "MMHG"],
                            :beat_per_minute => ["B/m", "b/m", "bpm", "BPM", "BpM"],
                            :centimeter_of_water => ["cmH2O", "cmh2o"],
                            :unknown => [""])

# The case-sensitivity of EDF physical dimension names means you can't/shouldn't
# naively convert/lowercase them to compliant Onda unit names, so we have to be
# very conservative here and error if we don't recognize the input.
function edf_to_onda_unit(edf_physical_dimension::AbstractString)
    edf_physical_dimension = replace(edf_physical_dimension, r"\s"=>"")
    for (onda_unit, potential_edf_matches) in STANDARD_UNITS
        any(==(edf_physical_dimension), potential_edf_matches) && return onda_unit
    end
    error("""
          Failed to convert EDF physical dimension label `$(edf_physical_dimension)`
          to known Onda unit; please either open a PR to add this unknown unit
          to `OndaEDF.STANDARD_UNITS` (if the unit obeys the EDF standard),
          or otherwise preprocess your EDF such that physical dimension labels
          contain known/standard values.
          """)
end

function onda_to_edf_unit(onda_sample_unit::Symbol)
    haskey(STANDARD_UNITS, onda_sample_unit) && return first(STANDARD_UNITS[onda_sample_unit])
    error("""
          Failed to convert Onda unit `$(onda_sample_unit)` to EDF physical dimension
          label; please either open a PR to add this unknown unit to `OndaEDF.STANDARD_UNITS`
          (if the unit obeys the EDF standard), or otherwise preprocess your input data such
          that their unit names are known/standard values.
          """)
end

const STANDARD_LABELS = Dict(# This EEG channel name list is a combined 10/20 and 10/10
                             # physical montage; channels are ordered from left-to-right,
                             # front-to-back w.r.t a top-down, nose-up view of the head.
                             # 10/20 channel names that aren't in the 10/10 system (and
                             # vice versa) are interleaved into their appropriate location
                             # on the head relative to other channels.
                             #
                             # Note that other commonly used (but non-EDF-standard) labels
                             # used as references include `LE` ("Linked Ear") and `AR`
                             # ("Average Reference"). See the following paper for details:
                             # https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5479869/
                             ["eeg"] => ["pg1", "nz", "pg2",
                                        "fp1", "fpz", "fp2",
                                        "af7", "af3", "afz", "af4", "af8",
                                        "f9", "f7", "f5", "f3", "f1", "fz", "f2", "f4", "f6", "f8", "f10",
                                        "ft9", "ft7", "fc5", "fc3", "fc1", "fcz", "fc2", "fc4", "fc6", "ft8", "ft10",
                                        "a1", "m1", "t9", "t7", "t3", "c5", "c3", "c1", "cz", "c2", "c4", "c6", "t4", "t8", "t10", "a2", "m2",
                                        "tp9", "tp7", "cp5", "cp3", "cp1", "cpz", "cp2", "cp4", "cp6", "tp8", "tp10",
                                        "t5", "p9", "p7", "p5", "p3", "p1", "pz", "p2", "p4", "p6", "p8", "p10", "t6",
                                        "po7", "po3", "poz", "po4", "po8",
                                        "o1", "oz", "o2",
                                        "iz"],
                             # It is very common in the wild to see "EKG1", "EKG2", etc., and it's not possible
                             # by label alone to tell whether such channels refer to I, II, etc. or aVL, aVR,
                             # etc., so there's a burden on users to preprocess their EKG labels
                             ["ecg", "ekg"] => ["i", "ii", "iii",
                                              "avl"=> ["ecgl", "ekgl", "ecg", "ekg", "l"], "avr"=> ["ekgr", "ecgr", "r"], "avf",
                                              "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9",
                                              "v1r", "v2r", "v3r", "v4r", "v5r", "v6r", "v7r", "v8r", "v9r",
                                              "x", "y", "z"],
                             ["eog"] => ["left"=> ["eogl", "loc", "lefteye", "leye", "e1", "l"],
                                        "right"=> ["eogr", "roc", "righteye", "reye", "e2", "r"]],
                             ["emg"] => ["chin1", "chin2", "chin3",
                                        "intercostal"=> ["ic"],
                                        "left_anterior_tibialis"=> ["lat", "l"],
                                        "right_anterior_tibialis"=> ["rat", "r"]],
                             ["heart_rate"] => ["heart_rate"=> ["hr"]],
                             ["snore"] => ["snore"],
                             ["positive_airway_pressure", "pap"] => ["ipap", "epap", "cpap"],
                             ["pap_device_cflow"] => ["pap_device_cflow"=> ["cflow", "airflow", "flow"]],
                             ["pap_device_cpres"] => ["pap_device_cpres"=> ["cpres"]],
                             ["pap_device_leak"] => ["pap_device_leak"=> ["leak", "airleak"]],
                             ["ptaf"] => ["ptaf"],
                             ["respiratory_effort"] => ["chest", "abdomen"=> ["abd"]],
                             ["tidal_volume"] => ["tidal_volume"=> ["tvol", "tidal"]],
                             ["spo2"] => ["spo2"],
                             ["sao2"] => ["sao2"],
                             ["etco2"] => ["etco2 "=> ["capno"]])

const STANDARD_EXTRACTORS = [edf -> extract_channels_by_label(edf, signal_names, channel_names)
                             for (signal_names, channel_names) in STANDARD_LABELS]
