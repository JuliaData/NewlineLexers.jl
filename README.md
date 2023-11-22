# NewlineLexers.jl

Quote-aware newline finder. By default it uses a branchless algorithm to find newlines, and is able to skip those which appear inside string fields. This is useful for parsing CSV files, for example, where we want to quickly find all newlines that separate individual records.

```julia
julia> data = collect(codeunits(""" abc\n "efg\n" \n """));

# Quote-unaware newline finder
julia> newlines = findall(==(UInt8('\n')), data)
3-element Vector{Int64}:
  5
 11
 14

#                                escape       open quote  close quote
julia> l = Lexer(IOBuffer(data), UInt8('\\'), UInt8('"'), UInt8('"'));

julia> out = Int32[];

# Doesn't include the newline that appears inside a string
julia> find_newlines!(l, data, out); # max size of `data` is 2GiB

julia> out
2-element Vector{Int32}:
  5
 14
```

## Acknowledgement

This package was heavily inspired by the [simdjson](https://github.com/simdjson/simdjson) library by Daniel Lemire, namely by his branchless approach to finding escape characters which we reused almost verbatim where applicable.

## Note

To avoid codegen issues with PackageCompiler we disable the usage of avx2/sse3/clmul instructions unless `NEWLINELEXERS_NATIVE` variable is set.