module NewlineLexers

using SIMD, ScanByte, Libdl

export Lexer, find_newlines!, possibly_not_in_string
# const compat
macro constfield(ex)
    @static if VERSION < v"1.8"
        return esc(ex)
    else
        return Expr(:const, esc(ex))
    end
end

# To work around https://github.com/JuliaLang/julia/issues/49653
# Specifically, when there is a multiversioning problem with PackageCompiler
# on Julia 1.8. This is perhaps overly conservative, as the issue only
# happens with PackageCompiler and only when targetting multiple cpu targets.
# TODO: use Preferences.jl and more granular feature settings
# const _AVOID_PLATFORM_SPECIFIC_LLVM_CODE = get(ENV, "JULIA_CPU_TARGET", "-Cnative" in Base.julia_cmd().exec ? "native" : "") != "native"
const _AVOID_PLATFORM_SPECIFIC_LLVM_CODE = get(ENV, "NEWLINELEXERS_NATIVE", "false") == "false"

# Compare two vectors of 64 bytes and produce an UInt64 where the set bits
# indicate the positions where the two vectors match.
@generated function __icmp_eq_u64(x::SIMD.Intrinsics.LVec{64, T}, y::SIMD.Intrinsics.LVec{64, T}) where {T <: SIMD.Intrinsics.IntegerTypes}
    s = """
    %res = icmp eq <64 x $(SIMD.Intrinsics.d[T])> %0, %1
    %resb = bitcast <64 x i1> %res to i64
    ret i64 %resb
    """
    return :(
        $(Expr(:meta, :inline));
        Base.llvmcall($s, UInt64, Tuple{SIMD.Intrinsics.LVec{64, T}, SIMD.Intrinsics.LVec{64, T}}, x, y)
    )
end
@inline function _icmp_eq_u64(x::Vec{64, T}, y::Vec{64, T}) where {T <: SIMD.Intrinsics.IntegerTypes}
    __icmp_eq_u64(x.data, y.data)
end
let # Feature detection -- copied from ScanByte.jl
    llvmpath = if VERSION ≥ v"1.6.0-DEV.1429"
        Base.libllvm_path()
    else
        only(filter(lib->occursin(r"LLVM\b", basename(lib)), Libdl.dllist()))
    end
    libllvm = Libdl.dlopen(llvmpath)
    gethostcpufeatures = Libdl.dlsym(libllvm, :LLVMGetHostCPUFeatures)
    features_cstring = ccall(gethostcpufeatures, Cstring, ())
    features = split(unsafe_string(features_cstring), ',')
    Libc.free(features_cstring)

    # prefix_xor works like this: it goes through the bits of the input UInt from least significant to most significant
    # and it xors the current bit with the previous one. This means that it starts producing 0 until it meets the first 1, then
    # it starts producing 1s until it meets the next 1, then it starts producing 0s again, etc.
    # Example:
    #    0b00001000010
    # -> 0b00000111110
    @eval if _AVOID_PLATFORM_SPECIFIC_LLVM_CODE || !any(x->occursin("clmul", x), $(features))
        @inline function prefix_xor(q)
            mask = q ⊻ (q << 1)
            mask = mask ⊻ (mask << 2)
            mask = mask ⊻ (mask << 4)
            mask = mask ⊻ (mask << 8)
            mask = mask ⊻ (mask << 16)
            mask = mask ⊻ (mask << 32)
            return mask
        end
    else
        # Cool explainer on carryless multiplication: https://wunkolo.github.io/post/2020/05/pclmulqdq-tricks/
        function carrylessmul(a::NTuple{2,VecElement{UInt64}}, b::NTuple{2,VecElement{UInt64}})
            ccall("llvm.x86.pclmulqdq", llvmcall, NTuple{2,VecElement{UInt64}}, (NTuple{2,VecElement{UInt64}}, NTuple{2,VecElement{UInt64}}, UInt8), a, b, 0)
        end

        @inline function prefix_xor(q)
            _q = (VecElement(UInt64(q)), VecElement(UInt64(0)))
            return @inbounds carrylessmul(_q, (VecElement(typemax(UInt64)), VecElement(typemax(UInt64))))[1].value
        end
    end
end

@static if _AVOID_PLATFORM_SPECIFIC_LLVM_CODE
    # The first argument is used to dispatch on a detected CPU feature set,
    # in this case we want to use the generic fallback, so we provide "nothing".
    @inline _internal_memchr(ptr::Ptr{UInt8}, len::UInt, valbs::Val) = ScanByte._memchr(nothing, ScanByte.SizedMemory(Ptr{UInt8}(ptr), len), valbs)
end
@static if !_AVOID_PLATFORM_SPECIFIC_LLVM_CODE
    @inline function _internal_memchr(ptr::Ptr{UInt8}, len::UInt, valbs::Val)
        ScanByte.memchr(ScanByte.SizedMemory(Ptr{UInt8}(ptr), len), valbs)
    end
end
@inline _internal_memchr(ptr::Ptr{UInt8}, len::UInt, byte::UInt8) = ScanByte.memchr(ScanByte.SizedMemory(Ptr{UInt8}(ptr), len), byte)

const _DOUBLEQUOTE64 = Vec(ntuple(_->VecElement(UInt8('"')), 64))
const _SINGLEQUOTE64 = Vec(ntuple(_->VecElement(UInt8('\'')), 64))
const _BACKSLASH64 = Vec(ntuple(_->VecElement(UInt8('\\')), 64))
const _LINEFEED64 = Vec(ntuple(_->VecElement(UInt8('\n')), 64))
const _CARRIAGERETURN64 = Vec(ntuple(_->VecElement(UInt8('\r')), 64))

function _get_char_vec64(c::UInt8)
    c == UInt8('"') && return _DOUBLEQUOTE64
    c == UInt8('\'') && return _SINGLEQUOTE64
    c == UInt8('\\') && return _BACKSLASH64
    c == UInt8('\n') && return _LINEFEED64
    c == UInt8('\r') && return _CARRIAGERETURN64
    return Vec(ntuple(_->VecElement(c), 64))
end

# Rules for Lexer{Q,Q,Q} when there is ambiguity between quotechar and escapechar:
# we use `prev_escaped` and `prev_in_string` to disambiguate the 4 cases:
# ---------+--------------------+--------------------+--------------------------------------
# prev end |    -> prev_escaped |  -> prev_in_string | Comment -- we ended...
# ---------+--------------------+--------------------+--------------------------------------
#   ..."a" | 0x0000000000000001 | 0xffffffffffffffff | inside a string on what might be an escape (or end of a string)
#   ..."ab | 0x0000000000000000 | 0xffffffffffffffff | inside a string on what cannot be an escape
#   ...ab" | 0x0000000000000001 | 0x0000000000000000 | on a quote or an odd sequence of quotes
#   ...a"" | 0x0000000000000000 | 0x0000000000000000 | on a non-quote or an even sequence of quotes
# ---------+--------------------+--------------------+--------------------------------------
# For Lexer{E,Q,Q}:
# ---------+--------------------+--------------------+--------------------------------------
# prev end |    -> prev_escaped |  -> prev_in_string | Comment -- we ended...
# ---------+--------------------+--------------------+--------------------------------------
#   ..."a" | 0x0000000000000000 | 0x0000000000000000 | on the very end of a string
#   ..."ab | 0x0000000000000000 | 0xffffffffffffffff | inside a string
#   ...ab" | 0x0000000000000000 | 0xffffffffffffffff | on the very beginning of a string
#   ...a"" | 0x0000000000000000 | 0x0000000000000000 | on the very end of an empty string
#   ...a"\ | 0x0000000000000001 | 0xffffffffffffffff | inside a string on an escape
#   ...a\\ | 0x0000000000000000 | 0x0000000000000000 | we ended on an escaped escape char (this is prob not valid CSV)
#   ...ab\ | 0x0000000000000001 | 0x0000000000000000 | outside a string on an escape (this is prob not valid CSV)
# ---------+--------------------+--------------------+--------------------------------------

# These must be respected in the `_find_newlines_kernel!` and `_find_newlines_generic!`
# All other cases are unambiguous, i.e. we can tell if we are inside a string or not,
# and if we are, we can tell if we are on an escape or not.
"""
    Lexer{E,OQ,CQ,NL,IO_t}

    Lexer(io, escapechar, openquotechar, closequotechar, newline) -> Lexer{E,OQ,CQ,NL,IO_t}
    Lexer(io, nothing, newline) -> Lexer{Nothing,Nothing,Nothing,NL,IO_t}

A stateful lexer type for newline detection. Use with the `find_newlines!` function.
The type parameters are:

- `E`: the escape character
- `OQ`: the open quote character
- `CQ`: the close quote character
- `NL`: the newline character
- `IO_t`: the type of the IO object, e.g. `IOBuffer` or `IOStream`

Either `E`, `OQ`, and `CQ` are all `Nothing`, or they are all single-byte characters.

When `E`, `OQ`, and `CQ` are not `Nothing`, the lexer will find all newlines in the input,
that are not inside a string (between two quotes). This is useful for finding record separators
in CSVs.

If they are all `Nothing`, the lexer will be quote-unaware, and find all newlines in the input,
regardless of whether they are inside a string or not. You can construct such a lexer with
`Lexer(io, nothing, newline)`.
"""
mutable struct Lexer{E,OQ,CQ,NL,IO_t}
    @constfield io::IO_t
    @constfield escape::Vec{64, UInt8}
    @constfield quotechar::Vec{64, UInt8}
    @constfield newline::Vec{64, UInt8}
    prev_escaped::UInt   # 0 or 1, see the tables above
    prev_in_string::UInt # 0 or typemax(UInt), see the tables above
    done::Bool           # Right now, this is not used but could be set by the caller

    function Lexer(
        io::IO_t,
        escapechar::Union{Char,UInt8}=UInt8('"'),
        openquotechar::Union{Char,UInt8}=UInt8('"'),
        closequotechar::Union{Char,UInt8}=UInt8('"'),
        newline::Union{Char,UInt8}=UInt8('\n'),
    ) where {IO_t}
        NL = _get_char_vec64(UInt8(newline))
        E = _get_char_vec64(UInt8(escapechar))
        if escapechar == openquotechar
            Q = E
        else
            Q = _get_char_vec64(UInt8(openquotechar))
        end
        return new{UInt8(escapechar), UInt8(openquotechar), UInt8(closequotechar), UInt8(newline), IO_t}(
            io, E, Q, NL, UInt(0), UInt(0), false
        )
    end

    function Lexer(io::IO_t, ::Nothing, newline::Union{Char,UInt8}=UInt8('\n')) where {IO_t}
        NL = _get_char_vec64(UInt8(newline))
        return new{Nothing, Nothing, Nothing, UInt8(newline), IO_t}(io, NL, NL, NL, UInt(0), UInt(0), false)
    end
end

escapechar(::Lexer{E,OQ,CQ,NL})     where {E,OQ,CQ,NL} = E
openquotechar(::Lexer{E,OQ,CQ,NL})  where {E,OQ,CQ,NL} = OQ
closequotechar(::Lexer{E,OQ,CQ,NL}) where {E,OQ,CQ,NL} = CQ
newline(::Lexer{E,OQ,CQ,NL})        where {E,OQ,CQ,NL} = NL

function Base.show(io::IO, l::Lexer{E,OQ,CQ,NL}) where {E,OQ,CQ,NL}
    _f(x) = x === Nothing ? "Nothing" : repr(Char(x))
    print(io, "Lexer{", _f(E), ", ", _f(OQ), ", ", _f(CQ), ", ", repr(Char(NL)))
    print(io, ", $(typeof(l.io))")
    l.done && print(io, " (done)")
    print(io, "}")
    if l.prev_escaped > 0 && l.prev_in_string > 0
        print(io, " [E|Q]")
    elseif l.prev_escaped == 0 && l.prev_in_string > 0
        print(io, " [Q]")
    elseif l.prev_escaped > 0 && l.prev_in_string == 0
        print(io, " [E]")
    end
end

# Returns a valid `bytes` for `ScanByte.memchr(..., bytes)`
@generated _scanbyte_bytes(::Lexer{E,OQ,CQ,NL}) where {E,OQ,CQ,NL} = Val(ScanByte.ByteSet((E,OQ,CQ,NL)))
@generated _scanbyte_bytes(::Lexer{Nothing,Nothing,Nothing,NL}) where {NL} = NL

# Take a 64-byte input and produce a 64-bit integer where the bits are set
# if the corresponding byte is a newline, quotechar, or escapechar
@inline compress_newlines(l::Lexer, input::Vec{64, UInt8}) = _icmp_eq_u64(input, l.newline)
@inline compress_quotes(l::Lexer, input::Vec{64, UInt8}) = _icmp_eq_u64(input, l.quotechar)
@inline compress_escapes(l::Lexer, input::Vec{64, UInt8}) = _icmp_eq_u64(input, l.escape)

# Should only be called if we are at the very end of a file to know if we ended
# in an unfinished string or not
possibly_not_in_string(l::Lexer{Q,Q,Q}) where {Q} = (l.prev_in_string & UInt(1)) == l.prev_escaped
possibly_not_in_string(l::Lexer{E,Q}) where {E,Q} = l.prev_in_string == 0

# This is where we process 64 byte input when the quotechar and escapechar are identical.
# This is our adaptation of the original `simdjson` implementation which handles the escaping rules
# common in CSVs.
#
# An example showing intermediate results when parsing 64 bytes with one quoted newline in a
# string and one unquoted newline:
# Note all the bits are reversed for readability. `*` marks the newlines.
#
#      "abc,"quoted,field","quoted*newline","escaped"" """" """"",01234*"
# X   0b0000100000000000010100000000000000101000000011011110111110000000
# F   0b0000010000000000001010000000000000010100000001101111011111000000
# SEQ 0b0000100000000000010100000000000000101000000010010000100000000000
# EB  0b1010101010101010101010101010101010101010101010101010101010101010
# OS  0b0000000000000000010100000000000000000000000000010000000000000000
# ES  0b0000100000000000000000000000000000101000000010000000100000000000
# OC  0b0000000000000000001010000000000000000000000000000000000000000000
# EC  0b0000010000000000000000000000000000010100000000000000000001000000
# Q   0b0000100000000000010100000000000000101000000000000000000010000000
# PX  0b0000111111111111100111111111111111001111111111111111111100000000
# STR 0b0000111111111111100111111111111111001111111111111111111100000000
# NL  0b0000000000000000000000000000000000000000000000000000000000000001
#      "abc,"quoted,field","quoted*newline","escaped"" """" """"",01234*
@inline function _find_newlines_kernel!(l::Lexer{Q,Q,Q}, input::Vec{64, UInt8}) where {Q}
    escape_chars = compress_escapes(l, input)
    follows_escape = escape_chars << 1
    # If there is a sequnce of Qs, the this will mark the beginning of the sequence
    # 0b000001111000000011110000001111111000010110111000001111111110
    # 0b000000001000000000010000000000001000010010001000000000000010
    sequence_starts = escape_chars & ~follows_escape

    even_bits = 0x5555_5555_5555_5555
    # We need to split sequences starting on even and odd bits so later we
    # we can check if the length of the sequence was odd (", """) or even ("", """")
    # Sequences with even lengths are always fully escaped.
    odd_sequence_starts = sequence_starts & ~even_bits
    even_sequence_starts = sequence_starts & even_bits

    # Check for overflow tells us that the sequence might spill to the next input
    # Example 1:
    #   0b000001111000000011110000001111111000010110111000001111111110 # seq doesn't end on boundary
    # + 0b000000001000000000010000000000001000010010001000000000000010
    # = 0b000010000000000100000000010000000000101001000000010000000000 # no overflow
    # Example 2:
    #   0b100001111000000011110000001111111000010110111000001111111110 # seq does end on boundary
    # + 0b100000001000000000010000000000001000010010001000000000000010 # NOTE: first bits are set
    # = 0b000010000000000100000000010000000000101001000000010000000000 # overflow
    even_sequence_carries = even_sequence_starts + escape_chars
    odd_sequence_carries, _overflowed_odd = Base.add_with_overflow(odd_sequence_starts, escape_chars)

    odd_string_starts = (odd_sequence_carries & ~escape_chars & even_bits)
    even_string_starts = (even_sequence_carries & ~escape_chars & ~even_bits)
    # This ignores strings that are entirely made up of quotes, e.g. "", """", etc.
    # But those cannot contain newlines so we don't care
    # Shift by one as carries are always one bit off due to the addition 0b0001 + 0b0001 = 0b0010
    # When `l.prev_escaped` is set, it means we ended on an unescaped quote, so we need to add
    # it here.
    quotes = ((even_string_starts | odd_string_starts) >> 1) ⊻ l.prev_escaped
    in_string = prefix_xor(quotes) ⊻ l.prev_in_string
    newlines = compress_newlines(l, input) & ~in_string

    # println(
    #     "\n      $l",
    #     "\n     \"", replace(join(map(x->Char(x.value), collect(input.data))), "\n" => "*"), "\"",
    #     "\nX   0b", bitstring(SIMD.Intrinsics.bitreverse(escape_chars)),
    #     "\nF   0b", bitstring(SIMD.Intrinsics.bitreverse(follows_escape)),
    #     "\nSEQ 0b", bitstring(SIMD.Intrinsics.bitreverse(sequence_starts)),
    #     "\nEB  0b", bitstring(SIMD.Intrinsics.bitreverse(even_bits)),
    #     "\nOS  0b", bitstring(SIMD.Intrinsics.bitreverse(odd_sequence_starts)),
    #     "\nES  0b", bitstring(SIMD.Intrinsics.bitreverse(even_sequence_starts)),
    #     "\nOC  0b", bitstring(SIMD.Intrinsics.bitreverse(odd_string_starts)),
    #     "\nEC  0b", bitstring(SIMD.Intrinsics.bitreverse(even_string_starts)),
    #     "\nQ   0b", bitstring(SIMD.Intrinsics.bitreverse(quotes)),
    #     "\nPX  0b", bitstring(SIMD.Intrinsics.bitreverse(prefix_xor(quotes))),
    #     "\nSTR 0b", bitstring(SIMD.Intrinsics.bitreverse(in_string)),
    #     "\nNL  0b", bitstring(SIMD.Intrinsics.bitreverse(newlines)),
    #     "\n     \"", replace(join(map(x->Char(x.value), collect(input.data))), "\n" => "*"), "\"",
    #     "\n[E] 0b", bitstring(SIMD.Intrinsics.bitreverse(UInt(_overflowed_odd))),
    #     "\n[Q] 0b", bitstring((in_string >> 63) * typemax(UInt)),
    # )

    l.prev_in_string = (in_string >> 63) * typemax(UInt)
    l.prev_escaped = UInt(_overflowed_odd)
    return newlines
end

# This is where we process 64 byte input when the quotechar and escapechar are different characters.
# In this case we follow the implementation from `simdjson`.
# See section "3.1.1 Identification of the quoted substrings" in https://arxiv.org/pdf/1902.08318.pdf
#
# An example showing intermediate results when parsing 64 bytes with one quoted newline in a
# string and one unquoted newline:
# Note all the bits are reversed for readability. `*` marks the newlines.
#
#      "abc,"quoted,field","quoted*newline","escaped\\ \\\\ \"\"",01234*"
# X   0b0000000000000000000000000000000000000000000011011110101000000000
# F   0b0000000000000000000000000000000000000000000001101111010100000000 X << 1 | l.prev_escaped
# EB  0b1010101010101010101010101010101010101010101010101010101010101010
# OS  0b0000000000000000000000000000000000000000000000010000000000000000 X & ~EB & ~F
# EC  0b0000000000000000000000000000000000000000000011000001101000000000 X + OS
# IM  0b0000000000000000000000000000000000000000000001100000110100000000 EC << 1
# E   0b0000000000000000000000000000000000000000000001001010010100000000 (EB ⊻ IM) & F
# Q   0b0000100000000000010100000000000000101000000000000000000010000000 quotes & ~E
# STR 0b0000111111111111100111111111111111001111111111111111111100000000 CLMUL(Q)
# NL  0b0000000000000000000000000000000000000000000000000000000000000001
@inline function _find_newlines_kernel!(l::Lexer{E,Q,Q}, input::Vec{64, UInt8}) where {E,Q}
    escape_chars = compress_escapes(l, input) & ~l.prev_escaped
    follows_escape = escape_chars << 1 | l.prev_escaped

    even_bits = 0x5555_5555_5555_5555
    odd_sequence_starts = escape_chars & ~even_bits & ~follows_escape
    sequences_starting_on_even_bits, _overflowed_odd = Base.add_with_overflow(odd_sequence_starts, escape_chars)
    invert_mask = sequences_starting_on_even_bits << 1
    escaped = (even_bits ⊻ invert_mask) & follows_escape
    quotes = compress_quotes(l, input) & ~escaped
    in_string = prefix_xor(quotes) ⊻ l.prev_in_string
    newlines = compress_newlines(l, input) & ~in_string

    # println(
    #     "\n      $l",
    #     "\n     \"", replace(join(map(x->Char(x.value), collect(input.data))), "\n" => "*"), "\"",
    #     "\nX   0b", bitstring(SIMD.Intrinsics.bitreverse(escape_chars)),
    #     "\nF   0b", bitstring(SIMD.Intrinsics.bitreverse(follows_escape)), " X << 1 | l.prev_escaped",
    #     "\nEB  0b", bitstring(SIMD.Intrinsics.bitreverse(even_bits)),
    #     "\nOS  0b", bitstring(SIMD.Intrinsics.bitreverse(odd_sequence_starts)), " X & ~EB & ~F",
    #     "\nEC  0b", bitstring(SIMD.Intrinsics.bitreverse(sequences_starting_on_even_bits)), " X + OS",
    #     "\nIM  0b", bitstring(SIMD.Intrinsics.bitreverse(invert_mask)), " EC << 1",
    #     "\nE   0b", bitstring(SIMD.Intrinsics.bitreverse(escaped)), " (EB ⊻ IM) & F",
    #     "\nQ   0b", bitstring(SIMD.Intrinsics.bitreverse(quotes)), " quotes & ~E",
    #     "\nSTR 0b", bitstring(SIMD.Intrinsics.bitreverse(in_string)), " CLMUL(Q)",
    #     "\nNL  0b", bitstring(SIMD.Intrinsics.bitreverse(newlines)),
    #     "\n     \"", replace(join(map(x->Char(x.value), collect(input.data))), "\n" => "*"), "\"",
    #     "\n[E] 0b", bitstring(SIMD.Intrinsics.bitreverse(UInt(_overflowed_odd))),
    #     "\n[Q] 0b", bitstring((in_string >> 63) * typemax(UInt)),
    # )

    l.prev_in_string = (in_string >> 63) * typemax(UInt)
    l.prev_escaped = UInt(_overflowed_odd)
    return newlines
end

# Generic fallback for when open and close quote differs and when buffer, or its last trailing bytes are too small for SIMD, i.e. < 64 bytes).
function _find_newlines_generic!(l::Lexer{E,OQ,CQ}, buf, out, curr_pos::Int=firstindex(buf), end_pos::Int=lastindex(buf)) where {E,OQ,CQ}
    @assert (1 <= curr_pos <= end_pos <= length(buf) && end_pos <= typemax(Int32))
    structural_characters = _scanbyte_bytes(l)

    ptr = pointer(buf)
    bytes_to_search = end_pos - curr_pos + 1
    offset = unsafe_trunc(Int32, curr_pos) - Int32(1)
    quoted = l.prev_in_string > 0
    ended_on_escape = l.prev_escaped > 0

    if ended_on_escape
        if E == CQ # Here is where we resolve the ambiguity from the last chunk
            @inbounds if buf[curr_pos] == E
                # The last byte of the previous chunk was actually escaping a quote or escape char
                # we can just skip over it
                offset += Int32(1)
                bytes_to_search -= 1
            else
                # The last byte of the previous chunk was not an escape but a quote
                quoted = !quoted
            end
        else
            offset += Int32(1)
            bytes_to_search -= 1
        end
    end

    ptr += offset
    ended_on_escape = false
    byte_to_check = UInt8(0)
    @inbounds while bytes_to_search > 0
        # ScanByte seems to sometimes return an UInt instead of an Int in
        # some fallback implementations.
        pos_to_check = Base.bitcast(Int, something(_internal_memchr(ptr, Core.bitcast(UInt, bytes_to_search), structural_characters), 0))
        pos_to_check == 0 && break

        offset += unsafe_trunc(Int32, pos_to_check)
        byte_to_check = buf[offset]
        if quoted # We're inside a quoted field
            if byte_to_check == E
                if offset < unsafe_trunc(Int32, end_pos)
                    if buf[offset+Int32(1)] in (E, CQ)
                        pos_to_check += 1
                        offset += Int32(1)
                    elseif E == CQ
                        quoted = false
                    end
                else # end of chunk
                    # Note that when e == cq, we can't be sure if we saw a closing char
                    # or an escape char and we won't be sure until the next chunk arrives
                    # Since this is the last byte of the chunk it could be also the last
                    # byte of the entire file and ending on an unmatched quote is an error
                    ended_on_escape = true
                    break
                end
            elseif byte_to_check == CQ
                quoted = false
            end
        else
            if byte_to_check == OQ
                quoted = true
                if E == OQ
                    if offset < unsafe_trunc(Int32, end_pos)
                        if buf[offset+Int32(1)] in (E, CQ) # escaped quote
                            pos_to_check += 1
                            offset += Int32(1)
                            quoted = false
                        end
                    else # end of chunk
                        quoted = false
                        ended_on_escape = true
                        break
                    end
                end
            elseif byte_to_check == E
                # this will most likely trigger a parser error
                if offset < unsafe_trunc(Int32, end_pos)
                    if buf[offset+Int32(1)] in (E, CQ)
                        pos_to_check += 1
                        offset += Int32(1)
                    end
                else # end of chunk
                    ended_on_escape = true
                    break
                end
            elseif byte_to_check == CQ
                # this will most likely trigger a parser error
            else # newline
                push!(out, offset)
            end
        end
        ptr += pos_to_check
        bytes_to_search -= pos_to_check
    end
    l.prev_in_string = quoted * typemax(UInt)
    l.prev_escaped = ended_on_escape * UInt(1)
    return nothing
end

# Quote-unaware lexer we use for trailing bytes of inputs with length that is not a multiple of 64.
function _find_newlines_quote_unaware_scanbyte!(l::Lexer{E,OQ,CQ,NL}, buf::Vector{UInt8}, out::AbstractVector{Int32}, curr_pos::Int=firstindex(buf), end_pos::Int=lastindex(buf)) where {E,OQ,CQ,NL}
    @assert (1 <= curr_pos <= end_pos <= length(buf) && end_pos <= typemax(Int32))
    ptr = pointer(buf, curr_pos)
    bytes_to_search = end_pos - curr_pos + 1
    base = Int32(curr_pos - 1)
    while true
        # ScanByte seems to sometimes return an UInt instead of an Int in
        # some fallback implementations.
        new_pos = _internal_memchr(ptr, Core.bitcast(UInt, bytes_to_search), NL)
        if new_pos === nothing
            return nothing
        else
            new_pos = Base.bitcast(Int, new_pos)
            base += unsafe_trunc(Int32, new_pos::Int)
            push!(out, base)
        end
        ptr += new_pos::Int
        bytes_to_search -= new_pos::Int
    end
end

# Quote-unaware lexer which handles 64-byte aligned buffers and leaves the rest to `_find_newlines_quote_unaware_scanbyte!`.
function _find_newlines_quote_unaware_simd!(l::Lexer, buf::Vector{UInt8}, out::AbstractVector{Int32}, curr_pos::Int=firstindex(buf), end_pos::Int=lastindex(buf))
    @assert (1 <= curr_pos <= end_pos <= length(buf) && end_pos <= typemax(Int32))
    base = unsafe_trunc(Int32, curr_pos)
    @inbounds while curr_pos <= (end_pos - 63)
        input = vload(Vec{64, UInt8}, buf, curr_pos)
        newlines = compress_newlines(l, input)
        while newlines > 0
            push!(out, base + unsafe_trunc(Int32, trailing_zeros(newlines)))
            newlines = newlines & (newlines - UInt(1))
        end
        base += Int32(64)
        curr_pos += 64
    end

    @inbounds if curr_pos <= end_pos
        # slower fallback to handle non-64-bytes-aligned trailing end
        _find_newlines_quote_unaware_scanbyte!(l, buf, out, curr_pos, end_pos)
    end
end

"""
    find_newlines!(l::Lexer, buf::Vector{UInt8}, out::AbstractVector{Int32}, curr_pos::Int=firstindex(buf), end_pos::Int=lastindex(buf))

Find newlines in `buf[curr_pos:end_pos]` and push their positions to `out`. The newline positions are relative to the beginning of `buf`.
The type of the `Lexer` determines the rules for handling quotes and escapes. See `Lexer` for details.

`end_pos` must be less than `typemax(Int32)` and `1 <= curr_pos <= end_pos`.
"""
function find_newlines! end

# Generic fallback for when open and close quote differs (should be also used in case the buffer is too small for SIMD).
function find_newlines!(l::Lexer{E,OQ,CQ}, buf::Vector{UInt8}, out::AbstractVector{Int32}, curr_pos::Int=firstindex(buf), end_pos::Int=lastindex(buf)) where {E,OQ,CQ}
    (1 <= curr_pos <= end_pos <= length(buf) && end_pos <= typemax(Int32)) || throw(ArgumentError("Invalid range: $curr_pos:$end_pos, must be 1 <= curr_pos <= end_pos <= $(length(buf)) <= $(typemax(Int32))"))
    _find_newlines_generic!(l, buf, out, curr_pos, end_pos)
    return nothing
end
# Fast path for when no newlines may appear inside quotes.
function find_newlines!(l::Lexer{Nothing,Nothing,Nothing}, buf::Vector{UInt8}, out::AbstractVector{Int32}, curr_pos::Int=firstindex(buf), end_pos::Int=lastindex(buf))
    (1 <= curr_pos <= end_pos <= length(buf) && end_pos <= typemax(Int32)) || throw(ArgumentError("Invalid range: $curr_pos:$end_pos, must be 1 <= curr_pos <= end_pos <= $(length(buf)) <= $(typemax(Int32))"))
    _find_newlines_quote_unaware_simd!(l, buf, out, curr_pos, end_pos)
    return nothing
end

# Path for when open and close quote are the same (escape might be different or the same as the quote)
function find_newlines!(l::Lexer{E,Q,Q}, buf::Vector{UInt8}, out::AbstractVector{Int32}, curr_pos::Int=firstindex(buf), end_pos::Int=lastindex(buf)) where {E,Q}
    (1 <= curr_pos <= end_pos <= length(buf) && end_pos <= typemax(Int32)) || throw(ArgumentError("Invalid range: $curr_pos:$end_pos, must be 1 <= curr_pos <= end_pos <= $(length(buf)) <= $(typemax(Int32))"))
    base = unsafe_trunc(Int32, curr_pos)
    @inbounds while curr_pos <= (end_pos - 63)
        input = vload(Vec{64, UInt8}, buf, curr_pos)
        newlines = _find_newlines_kernel!(l, input)
        while newlines > 0
            push!(out, base + unsafe_trunc(Int32, trailing_zeros(newlines)))
            newlines = newlines & (newlines - UInt(1))
        end
        base += Int32(64)
        curr_pos += 64
    end

    @inbounds if curr_pos <= end_pos
        # slower fallback to handle non-64-bytes-aligned trailing end
        _find_newlines_generic!(l, buf, out, curr_pos, end_pos)
    end
    return nothing
end

end # module
