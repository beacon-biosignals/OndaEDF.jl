function _print_result_value(f, si::SamplesInfo; indent=0, kwargs...)
    print(f, "$(repeat(' ', indent))SamplesInfo(")
    print(f, join([repr(getproperty(si, field)) for field in fieldnames(SamplesInfo)], ", "))
    print(f, ")")
end

function _print_result_value(f, p::Pair; kwargs...)
    _print_result_value(f, first(p); kwargs...)
end

function _print_result_value(f, v::Vector; indent=0, tab=4)
    println(f, "$(repeat(' ', indent))[")
    for x in v
        _print_result_value(f, x; indent=indent + tab, tab=tab)
        println(f, ",")
    end
    print(f, "$(repeat(' ', indent))]")
end

_print_result_value(f, e; indent=0, kwargs...) = print(f, "$(repeat(' ', indent))$(repr(e))")

function print_result(f, r, label; indent=0, tab=4)
    println(f, "$(repeat(' ', indent))($(repeat(' ', indent-1))# $label")
    for (field, value) in pairs(r)
        println(f, "$(repeat(' ', indent + tab))$field=")
        _print_result_value(f, value; indent=2 * tab + indent)
        println(f, ",")
    end
    print(f, "$(repeat(' ', indent)))")
end

function print_results(f::IO, results)
    println(f, "[")
    for (i, result) in enumerate(results)
        print_result(f, result, i; indent=4)
        println(f, ",")
    end
    print(f, "]")
end

function print_results(filename_base::String, results)
    filename = "$(filename_base).out"
    open(filename, "w") do f
        print(f, "$(filename_base) = ")
        print_results(f, results)
        println(f)
    end
end

# include(*.out) can stack overflow if file is too big
# use batched version instead with batch_size=32000
# (not an issue with deduping of recording headers applied above)
function print_results(filename_base::String, results, batch_size)
    batches = Iterators.partition(results, batch_size)
    for (i, batch) in enumerate(batches)
        filename = "$(filename_base)_$i.out"
        open(filename, "w") do f
            i == 1 && println(f, "$(filename_base) = []")
            print(f, "append!($(filename_base), ")
            print_results(f, results)
            println(f, ")")
        end
    end
end
