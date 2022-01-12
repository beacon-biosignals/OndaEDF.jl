# https://www.edfplus.info/specs/edftexts.html

# This is a mapping from Onda-appropriate unit names to EDF standard physical dimensions.
# This doesn't cover everything, just units that we've seen often. Note that casing
# matters for the EDF standard physical dimensions, so we can't just always normalize
# to a single case when processing; this results in some redundant-looking values below.
const STANDARD_UNITS = Dict("nanovolt" => ["nV"],
                            "microvolt" => ["uV", "\xb5V", "\xb5V\xb2"],
                            "millivolt" => ["mV"],
                            "centivolt" => ["cV"],
                            "decivolt" => ["dV"],
                            "volt" => ["V", "v", "volts"],
                            "millimiter" => ["mm"],
                            "centimeter" => ["cm"],
                            "milliliter" => ["mL", "ml"],
                            "degrees_celsius" => ["degC", "degc"],
                            "degrees_fahrenheit" => ["degF", "degf"],
                            "kelvin" => ["K"],
                            "percent" => ["%"],
                            "liter_per_minute" => ["L/m", "l/m", "LPM", "Lpm", "lpm", "LpM", "L/min", "l/min"],
                            "millimeter_of_mercury" => ["mmHg", "mmhg", "MMHG"],
                            "beat_per_minute" => ["B/m", "b/m", "bpm", "BPM", "BpM", "Bpm"],
                            "centimeter_of_water" => ["cmH2O", "cmh2o", "cmH20"],
                            "ohm" => ["Ohm", "ohms", "Ohms", "ohm"],
                            "unknown" => ["", "\"\"", "#", "u", "none", "---"],
                            "relative" => ["rel."])

# The case-sensitivity of EDF physical dimension names means you can't/shouldn't
# naively convert/lowercase them to compliant Onda unit names, so we have to be
# very conservative here and error if we don't recognize the input.
function edf_to_onda_unit(edf_physical_dimension::AbstractString, unit_alternatives=STANDARD_UNITS)
    edf_physical_dimension = replace(edf_physical_dimension, r"\s"=>"")
    for (onda_unit, potential_edf_matches) in unit_alternatives
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

function onda_to_edf_unit(onda_sample_unit::String)
    haskey(STANDARD_UNITS, onda_sample_unit) && return first(STANDARD_UNITS[onda_sample_unit])
    error("""
          Failed to convert Onda unit `$(onda_sample_unit)` to EDF physical dimension
          label; please either open a PR to add this unknown unit to `OndaEDF.STANDARD_UNITS`
          (if the unit obeys the EDF standard), or otherwise preprocess your input data such
          that their unit names are known/standard values.
          """)
end

const STANDARD_LABELS = Dict(# This EEG channel name list is a combined 10/20, 10/10, and 10/05
                             # physical montage; channels are ordered from left-to-right,
                             # front-to-back w.r.t a top-down, nose-up view of the head.
                             # 10/20 channel names that aren't in the 10/10 system (and
                             # vice versa) are interleaved into their appropriate location
                             # on the head relative to other channels.
                             # Reference: Jurcak, V., Tsuzuki, D., and Dan, I. (2007). 
                             # 10/20, 10/10, and 10/5 systems revisited: Their validity as 
                             # relative head-surface-based positioning systems. NeuroImage 34,
                             # 1600-1611. https://doi.org/10.1016/j.neuroimage.2006.09.024.

                             #
                             # Note that other commonly used (but non-EDF-standard) labels
                             # used as references include `LE` ("Linked Ear") and `AR`
                             # ("Average Reference"). See the following paper for details:
                             # https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5479869/
                             ["eeg"] =>  ["nas",
                                          "n1", "n1h", "nz", "n2h", "n2", 
                                          "nfp1", "nfp1h", "nfpz", "nfp2h", "nfp2",
                                          "fp1", "fp1h", "fpz", "fp2h", "fp2", 
                                          "afp9", "afp9h", "afp7", "afp7h", "afp5", "afp5h", "afp3", "afp3h", "afp1", "afp1h", "afpz", "afp2h", "afp2", "afp4h", "afp4", "afp6h", "afp6", "afp8h", "afp8", "afp10h", "afp10", 
                                          "af9", "af9h",  "af7", "af7h", "af5", "af5h", "af3", "af3h", "af1", "af1h", "afz", "af2h", "af2", "af4h", "af4", "af6h", "af6",  "af8h", "af8", "af10h", "af10", 
                                          "aff9", "aff9h", "aff7", "aff7h", "aff5", "aff5h", "aff3", "aff3h", "aff1", "aff1h",  "affz", "aff2h", "aff2", "aff4h", "aff4", "aff6h",  "aff6", "aff8h",  "aff8", "aff10h", "aff10", 
                                          "f9", "f9h", "f7", "f7h",  "f5", "f5h", "f3", "f3h", "f1",  "f1h", "fz", "f2h", "f2", "f4h", "f4", "f6h", "f6", "f8h", "f8",  "f10h", "f10",
                                          "fft9", "fft9h", "fft7", "fft7h", "ffc5", "ffc5h", "ffc3", "ffc3h", "ffc1", "ffc1h", "ffcz", "ffc2h",  "ffc2",  "ffc4h", "ffc4", "ffc6h", "ffc6", "fft8h", "fft8", "fft10h", "fft10", 
                                          "ft9", "ft9h", "ft7", "ft7h", "fc5", "fc5h", "fc3", "fc3h", "fc1", "fc1h", "fcz", "fc2h", "fc2", "fc4h",  "fc4", "fc6h", "fc6", "ft8h", "ft8", "ft10h",  "ft10", 
                                          "ftt9", "ftt9h", "ftt7", "ftt7h", "fcc5", "fcc5h", "fcc3", "fcc3h", "fcc1", "fcc1h", "fccz", "fcc2h", "fcc2", "fcc4h", "fcc4", "fcc6h", "fcc6", "ftt8h", "ftt8", "ftt10h", "ftt10", 
                                          "t9", "t9h", "t7", "t7h", "c5", "c5h", "c3", "c3h", "c1", "c1h", "cz", "c2h", "c2", "c4h", "c4", "c6h", "c6", "t8h", "t8", "t10h", "t10", 
                                          "ttp9", "ttp9h", "ttp7", "ttp7h", "ccp5", "ccp5h", "ccp3", "ccp3h", "ccp1", "ccp1h", "ccpz", "ccp2h", "ccp2", "ccp4h",  "ccp4", "ccp6h",  "ccp6", "ttp8h", "ttp8", "ttp10h", "ttp10",
                                          "tp9", "tp9h", "tp7", "tp7h", "cp5", "cp5h", "cp3", "cp3h", "cp1", "cp1h", "cpz", "cp2h", "cp2", "cp4h", "cp4", "cp6h", "cp6", "tp8h", "tp8", "tp10h", "tp10", 
                                          "tpp9", "tpp9h", "tpp7", "tpp7h", "cpp5", "cpp5h", "cpp3", "cpp3h", "cpp1", "cpp1h",  "cppz", "cpp2h", "cpp2", "cpp4h", "cpp4", "cpp6h", "cpp6", "tpp8h", "tpp8", "tpp10h",  "tpp10", 
                                          "p9", "p9h", "p7", "p7h", "p5", "p5h", "p3", "p3h", "p1", "p1h", "pz", "p2h", "p2", "p4h", "p4", "p6h", "p6", "p8h", "p8", "p10h", "p10", 
                                          "ppo9", "ppo9h",  "ppo7", "ppo7h", "ppo5", "ppo5h", "ppo3", "ppo3h", "ppo1", "ppo1h", "ppoz", "ppo2h", "ppo2", "ppo4h", "ppo4", "ppo6h", "ppo6", "ppo8h", "ppo8", "ppo10h", "ppo10",
                                          "po9", "po9h", "po7", "po7h", "po5", "po5h", "po3", "po3h", "po1", "po1h", "poz", "po2h", "po2", "po4h", "po4", "po6h", "po6", "po8h",  "po8", "po10h", "po10",
                                          "poo9", "poo9h", "poo7", "poo7h", "poo5", "poo5h", "poo3", "poo3h", "poo1", "poo1h", "pooz", "poo2h", "poo2", "poo4h", "poo4", "poo6h", "poo6", "poo8h", "poo8", "poo10h", "poo10",
                                          "o1" => ["01"], "o1h", "oz", "o2h", "o2" => ["02"], 
                                          "oi1", "oi1h", "oiz", "oi2h", "oi2",
                                          "i1", "i1h", "iz", "i2h", "i2",

                                          "t3", "t4", "t5", "t6", # T3, T4, T5 and T6 in 10/20 system aren named T7, T8, P7, P8 in 10/10 system.
                                          "a1", "a2", "m1", "m2",
                                          "lpa", "rpa",
                                          "pg1", "pg2"],
                             # It is very common in the wild to see "EKG1", "EKG2", etc., and it's not possible
                             # by label alone to tell whether such channels refer to I, II, etc. or aVL, aVR,
                             # etc., so there's a burden on users to preprocess their EKG labels
                             ["ecg", "ekg"] => ["i" => ["1"], "ii" => ["2"], "iii" => ["3"],
                                                "avl"=> ["ecgl", "ekgl", "ecg", "ekg", "l"], "avr"=> ["ekgr", "ecgr", "r"], "avf",
                                                "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9",
                                                "v1r", "v2r", "v3r", "v4r", "v5r", "v6r", "v7r", "v8r", "v9r",
                                                "x", "y", "z"],
                             # EOG should not have any channel names overlapping with EEG channel names
                             ["eog", "eeg"] => ["left"=> ["eogl", "loc", "lefteye", "leye", "e1", "eog1", "l", "left eye", "leog", "log", "li"],
                                                "right"=> ["eogr", "roc", "righteye", "reye", "e2", "eog2", "r", "right eye", "reog", "rog", "re"]],
                             ["emg"] => ["chin1" => ["chn", "chin_1", "chn1", "kinn", "menton", "submental", "submentalis", "submental1", "subm1", "chin", "mentalis", "chinl", "chinli", "chinleft", "subm_1", "subment"],
                                         "chin2" => ["chn2", "chin_2", "submental2", "subm2", "chinr", "chinre", "chinright", "subm_2"],
                                         "chin3" => ["chn3", "submental3", "subm3", "chincenter"],
                                         "intercostal"=> ["ic"],
                                         "left_anterior_tibialis"=> ["lat", "lat1", "l", "left", "leftlimb", "tibl", "tibli", "plml", "leg1", "lleg", "lleg1", "legl", "jambe_l", "leftleg"],
                                         "right_anterior_tibialis"=> ["rat", "rat1", "r", "right", "rightlimb", "tibr", "tibre", "plmr", "leg2", "leg3", "rleg", "rleg1", "legr", "jambe_r", "rightleg"]],
                             # it is common to see ambiguous channels, which could be leg or face EMG
                             # if leg EMG is present in separate channels,
                             # post-processing might map "emg_ambiguous"
                             # to chin channels (for example)
                             ["emg_ambiguous", "emg"] => ["1" => ["aux1", "l"],
                                                          "2" => ["aux2", "r"],
                                                          "3" => ["aux3"]],
                             ["heart_rate"] => ["heart_rate"=> ["hr", "pulse", "pulso", "pr", "pulserate"]],
                             ["snore"] => ["snore" => ["ronquido", "ronquido derivad", "schnarchen", "ronfl", "schnarchmikro"]],
                             ["positive_airway_pressure", "pap"] => ["ipap", "epap", "cpap"],
                             ["pap_device_cflow"] => ["pap_device_cflow"=> ["cflow", "airflow", "flow"]],
                             ["pap_device_cpres"] => ["pap_device_cpres"=> ["cpres"]],
                             ["pap_device_leak"] => ["pap_device_leak"=> ["leak", "airleak"]],
                             ["ptaf"] => ["ptaf"],
                             ["respiratory_effort"] => ["chest" => ["thorax", "torax", "brust", "thor"], "abdomen"=> ["abd", "abdo", "bauch"]],
                             ["tidal_volume"] => ["tidal_volume"=> ["tvol", "tidal"]],
                             ["spo2"] => ["spo2"],
                             ["sao2"] => ["sao2", "osat"],
                             ["etco2"] => ["etco2 "=> ["capno"]])

const STANDARD_EXTRACTORS = [edf -> extract_channels_by_label(edf, signal_names, channel_names)
                             for (signal_names, channel_names) in STANDARD_LABELS]
