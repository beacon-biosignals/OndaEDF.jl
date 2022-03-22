# API Documentation

```@meta
CurrentModule = OndaEDF
```

## Import EDF to Onda

OndaEDF.jl prefers "self-service" import over "automagic", and provides
functionality to extract
[`Onda.Samples`](https://beacon-biosignals.github.io/Onda.jl/stable/#Samples-1)
and
[`Onda.Annotation`](https://beacon-biosignals.github.io/Onda.jl/stable/#Onda.Annotation)s
from an `EDF.File`.  These can be written to disk (with
[`Onda.store`](https://beacon-biosignals.github.io/Onda.jl/stable/#Onda.store) /
[`Onda.write_annotations`](https://beacon-biosignals.github.io/Onda.jl/stable/#Onda.write_annotations))
or manipulated in memory as desired.

```@docs
edf_to_onda_samples
plan_edf_to_onda_samples
plan_edf_to_onda_samples_groups
edf_to_onda_annotations
```

### Import plan table schemas

```@docs
Plan
FilePlan
write_plan
```

### Full-service import

For a more "full-service" experience, OndaEDF.jl also provides functionality to
extract `Onda.Samples` and `Onda.Annotations` and then write them to disk:

```@docs
store_edf_as_onda
```

### Internal import utilities

```@docs
match_edf_label
merge_samples_info
OndaEDF.onda_samples_from_edf_signals
```

## Export EDF from Onda

```@docs
onda_to_edf
```
