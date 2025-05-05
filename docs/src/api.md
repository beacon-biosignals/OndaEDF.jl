# API Documentation

```@meta
CurrentModule = OndaEDF
```

## Import EDF to Onda

OndaEDF.jl prefers "self-service" import over "automagic", and provides
functionality to extract
[`Onda.Samples`](https://beacon-biosignals.github.io/Onda.jl/stable/#Samples-1)
and [`EDFAnnotationV1`](@ref)s (which extend
[`Onda.AnnotationV1`](https://beacon-biosignals.github.io/Onda.jl/stable/#Onda.AnnotationV1)s)
from an `EDF.File`.  These can be written to disk (with
[`Onda.store`](https://beacon-biosignals.github.io/Onda.jl/stable/#Onda.store) /
[`Legolas.write`](https://beacon-biosignals.github.io/Legolas.jl/stable/#Legolas.write)
or manipulated in memory as desired.

### Import signal data as `Samples`

#### Import planning

```@docs
plan_edf_to_onda_samples
plan_edf_to_onda_samples_groups
```

#### Import execution

```@docs
edf_to_onda_samples
ConvertedSamples
get_plan
get_samples
Onda.store
```

### Import annotations

```@docs
edf_to_onda_annotations
EDFAnnotationV1
```

### Import plan table schemas

!!! note "Plan version is dependent on EDF.jl version"
    The utilized plan version is dependent on the EDF.jl version.
    For EDF.jl 0.8+, V3 are used, while V2 is used for for EDF.jl 0.7.
    The change from V2 to V3 reflects the change from [`Int16` to `Int32`
    in EDF.jl's `samples_per_record`](https://github.com/beacon-biosignals/EDF.jl/releases/tag/v0.8.0).

```@docs
PlanV4
FilePlanV4
```

### Full-service import

For a more "full-service" experience, OndaEDF.jl also provides functionality to
extract `Onda.Samples` and `EDFAnnotationV1`s and then write them to disk:

```@docs
store_edf_as_onda
```

### Internal import utilities

```@docs
OndaEDF.match_edf_label
OndaEDF.merge_samples_info
OndaEDF.onda_samples_from_edf_signals
OndaEDF.promote_encodings
```

## Export EDF from Onda

```@docs
onda_to_edf
```

#### Internal export utilities

```@docs
OndaEDF.reencode_samples
```

## Deprecations

To support deserializing plan tables generated with old versions of OndaEDF +
Onda, the following schemas are provided.  These are deprecated and will be
removed in a future release.

```@docs
PlanV1
PlanV2
PlanV3
FilePlanV1
FilePlanV2
FilePlanV3
```
