var documenterSearchIndex = {"docs":
[{"location":"#API-Documentation","page":"API Documentation","title":"API Documentation","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"CurrentModule = OndaEDF","category":"page"},{"location":"#Import-EDF-to-Onda","page":"API Documentation","title":"Import EDF to Onda","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"OndaEDF.jl prefers \"self-service\" import over \"automagic\", and provides functionality to extract Onda.Samples and Onda.Annotations from an EDF.File.  These can be written to disk (with Onda.store / Onda.write_annotations) or manipulated in memory as desired.","category":"page"},{"location":"","page":"API Documentation","title":"API Documentation","text":"edf_to_onda_samples\nedf_to_onda_annotations","category":"page"},{"location":"#OndaEDF.edf_to_onda_samples","page":"API Documentation","title":"OndaEDF.edf_to_onda_samples","text":"edf_to_onda_samples(edf::EDF.File; custom_extractors=())\n\nRead signals from an EDF.File into a vector of Onda.Samples.\n\nCollections of EDF.Signals are mapped as channels to Onda.Signals via simple \"extractor\" callbacks of the form:\n\nedf::EDF.File -> (samples_info::Onda.SamplesInfo,\n                  edf_signals::Vector{EDF.Signal})\n\nedf_to_onda_samples automatically uses a variety of default extractors derived from the EDF standard texts; see src/standards.jl for details. The caller can also provide additional extractors via the custom_extractors keyword argument.\n\nEDF.Signal labels that are converted into Onda channel names undergo the following transformations:\n\nthe label is whitespace-stripped, parens-stripped, and lowercased\ntrailing generic EDF references (e.g. \"ref\", \"ref2\", etc.) are dropped\nany instance of + is replaced with _plus_ and / with _over_\nall component names are converted to their \"canonical names\" when possible (e.g. \"m1\" in an EEG-matched channel name will be converted to \"a1\").\n\nSee the OndaEDF README for additional details regarding EDF formatting expectations.\n\n\n\n\n\n","category":"function"},{"location":"#OndaEDF.edf_to_onda_annotations","page":"API Documentation","title":"OndaEDF.edf_to_onda_annotations","text":"edf_to_onda_annotations(edf::EDF.File, uuid::UUID)\n\nExtract EDF+ annotations from an EDF.File for recording with ID uuid and return them as a vector of Onda.Annotations.  Each returned annotation has  a  value field that contains the string value of the corresponding EDF+  annotation. \n\nIf no EDF+ annotations are found in edf, then an empty Vector{Annotation} is  returned.\n\n\n\n\n\n","category":"function"},{"location":"#Import-utilities","page":"API Documentation","title":"Import utilities","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"extract_channels_by_label\nedf_signals_to_samplesinfo","category":"page"},{"location":"#OndaEDF.extract_channels_by_label","page":"API Documentation","title":"OndaEDF.extract_channels_by_label","text":"extract_channels_by_label(edf::EDF.File, signal_names, channel_names)\n\nFor one or more signal names and one or more channel names, return all matching signals from an EDF.File, and the Onda.SamplesInfo struct that describes the extracted channels.\n\nsignal_names should be an iterable of Strings naming the signal types to extract (e.g., [\"ecg\", \"ekg\"]; [\"eeg\"]).\n\nchannel_names should be an iterable of channel specifications, each of which can be either a String giving the generated channel name, or a Pair mapping a canonical name to a list of alternatives that it should be substituted for (e.g., \"canonical_name\" => [\"alt1\", \"alt2\", ...]).\n\nunit_alternatives lists standardized unit names and alternatives that map to them. See OndaEDF.STANDAR_UNITS for defaults.\n\npreprocess_labels(label::String) is applied to raw edf signal header labels beforehand; defaults to identity.\n\nSee OndaEDF.STANDARD_LABELS for the labels (signal_names => channel_names Pairs) that are used to extract EDF signals by default.\n\n\n\n\n\n","category":"function"},{"location":"#OndaEDF.edf_signals_to_samplesinfo","page":"API Documentation","title":"OndaEDF.edf_signals_to_samplesinfo","text":"edf_signals_to_samplesinfo(edf, edf_signals, kind, channel_names, samples_per_record; unit_alternatives=STANDARD_UNITS)\n\nGenerate a single Onda.SamplesInfo for the given collection of EDF.Signals corresponding to the channels of a single Onda signal.  Sample units are converted to Onda units and checked for consistency, and a promoted encoding (resolution, offset, and sample type/rate) is generated.\n\nNo conversion of the actual signals is performed at this step.\n\n\n\n\n\n","category":"function"},{"location":"#Full-service-import","page":"API Documentation","title":"Full-service import","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"For a more \"full-service\" experience, OndaEDF.jl also provides functionality to extract Onda.Samples and Onda.Annotations and then write them to disk:","category":"page"},{"location":"","page":"API Documentation","title":"API Documentation","text":"store_edf_as_onda","category":"page"},{"location":"#OndaEDF.store_edf_as_onda","page":"API Documentation","title":"OndaEDF.store_edf_as_onda","text":"store_edf_as_onda(path, edf::EDF.File, uuid::UUID=uuid4();\n                  custom_extractors=(), import_annotations::Bool=true,\n                  signals_prefix=\"edf\", annotations_prefix=signals_prefix)\n\nConvert an EDF.File to Onda.Samples and Onda.Annotations, store the samples in $path/samples/, and write the Onda signals and annotations tables to $path/$(signals_prefix).onda.signals.arrow and $path/$(annotations_prefix).onda.annotations.arrow.  The default prefix is \"edf\", and if a prefix is provided for signals but not annotations both will use the signals prefix.  The prefixes cannot reference (sub)directories.\n\nReturns uuid => (signals, annotations).\n\nSamples are extracted with edf_to_onda_samples, and EDF+ annotations are extracted with edf_to_onda_annotations if import_annotations==true (the default).\n\nCollections of EDF.Signals are mapped as channels to Onda.Signals via simple \"extractor\" callbacks of the form:\n\nedf::EDF.File -> (samples_info::Onda.SamplesInfo,\n                  edf_signals::Vector{EDF.Signal})\n\nstore_edf_as_onda automatically uses a variety of default extractors derived from the EDF standard texts; see src/standards.jl and extract_channels_by_label for details. The caller can also provide additional extractors via the custom_extractors keyword argument, and the edf_signals_to_samplesinfo utility can be used to extract a common Onda.SamplesInfo from a collection of EDF.Signals.\n\nEDF.Signal labels that are converted into Onda channel names undergo the following transformations:\n\nthe label is whitespace-stripped, parens-stripped, and lowercased\ntrailing generic EDF references (e.g. \"ref\", \"ref2\", etc.) are dropped\nany instance of + is replaced with _plus_ and / with _over_\nall component names are converted to their \"canonical names\" when possible (e.g. for an EOG matched channel, \"eogl\", \"loc\", \"lefteye\", etc. are converted to \"left\").\n\nSee the OndaEDF README for additional details regarding EDF formatting expectations.\n\n\n\n\n\n","category":"function"},{"location":"#Export-EDF-from-Onda","page":"API Documentation","title":"Export EDF from Onda","text":"","category":"section"},{"location":"","page":"API Documentation","title":"API Documentation","text":"onda_to_edf","category":"page"},{"location":"#OndaEDF.onda_to_edf","page":"API Documentation","title":"OndaEDF.onda_to_edf","text":"onda_to_edf(signals, annotations=[]; kwargs...)\n\nReturn an EDF.File containing signal data converted from the Onda signals table and (optionally) annotations from an annotations table.\n\nFollowing the Onda v0.5 format, both signals and annotations can be any Tables.jl-compatible table (DataFrame, Arrow.Table, NamedTuple of vectors, vector of NamedTuples) which follow the signal and annotation schemas (respectively).\n\nEach EDF.Signal in the returned EDF.File corresponds to a channel of an Onda.Signal.\n\nThe ordering of EDF.Signals in the output will match the order of the rows of the signals table (and within each channel grouping, the order of the signal's channels).\n\n\n\n\n\n","category":"function"}]
}
