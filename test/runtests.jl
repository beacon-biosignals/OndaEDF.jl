include("set_up_tests.jl")

@testset "OndaEDF" begin
    @testset "Aqua" begin
        Aqua.test_all(OndaEDF)
    end
    include("signal_labels.jl")
    include("import.jl")
    include("export.jl")
end
