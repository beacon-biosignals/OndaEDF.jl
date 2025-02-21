include("set_up_tests.jl")

@testset "OndaEDF" begin
    include("signal_labels.jl")
    include("import.jl")
    include("export.jl")
end
