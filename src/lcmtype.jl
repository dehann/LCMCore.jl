"""
    LCMType

Supertype of concrete Julia `struct`s that represent LCM message types.

Subtypes must be `mutable struct`s and may use the following field types:

* `Bool`
* numeric types: `Int8`, `Int16`, `Int32`, `Int64`, `Float32`, `Float64`
* bytes (encoded in the same was as `Int8`): `UInt8`;
* `String`;
* another `LCMType`;
* `Vector` or a subtype of `StaticVector`, for which the element type must also be
one of the previously specified types or another `Vector` or `StaticVector`.

The following methods must be defined for a concrete subtype of `LCMType` (say `MyType`):

* `check_valid(x::MyType)`
* `size_fields(::Type{MyType})`
* `fingerprint(::Type{MyType})`
* `Base.resize!(x::MyType)`

Any size fields must come **before** the `Vector` fields to which they correspond.

Note that ideally, all of these methods would be generated from the LCM message type
definition, but that is currently not the case.
"""
abstract type LCMType end

"""
size_fields(x::Type{T}) where T<:LCMType

Returns a tuple of `Symbol`s corresponding to the fields of `T` that represent vector dimensions.
"""
size_fields(x::Type{T}) where {T<:LCMType} = error("size_fields method not defined for LCMType $T.")

"""
check_valid(x::LCMType)

Check that `x` is a valid LCM type. For example, check that array lengths are correct.
"""
check_valid(x::LCMType) = error("check_valid method not defined for LCMType $(typeof(x)).")

"""
fingerprint(::Type{T}) where T<:LCMType

Return the fingerprint of LCM type `T` as an `SVector{8, UInt8}`.
"""
fingerprint(::Type{T}) where {T<:LCMType} = error("fingerprint method not defined for LCMType $T.")

# Types that are encoded in network byte order, as dictated by the LCM type specification.
const NETWORK_BYTE_ORDER_TYPES = Union{Int8, Int16, Int32, Int64, Float32, Float64, UInt8}

# Default values for all of the possible field types of an LCM type:
default_value(::Type{Bool}) = false
default_value(::Type{T}) where {T<:NETWORK_BYTE_ORDER_TYPES} = zero(T)
default_value(::Type{String}) = ""
default_value(::Type{T}) where {T<:Vector} = T()
default_value(::Type{SV}) where {N, T, SV<:StaticVector{N, T}} = SV(ntuple(i -> default_value(T), Val(N)))
default_value(::Type{T}) where {T<:LCMType} = T()

# Generated default constructor for LCMType subtypes
@generated function (::Type{T})() where T<:LCMType
    constructor_arg_exprs = [:(default_value(fieldtype(T, $i))) for i = 1 : fieldcount(T)]
    :(T($(constructor_arg_exprs...)))
end

# Fingerprint check
struct FingerprintException <: Exception
    T::Type
end

@noinline function Base.showerror(io::IO, e::FingerprintException)
    print(io, "LCM message fingerprint did not match type ", e.T, ". ")
    print(io, "This means that you are trying to decode the wrong message type, or a different version of the message type.")
end

function check_fingerprint(io::IO, ::Type{T}) where T<:LCMType
    decodefield(io, SVector{8, UInt8}) == fingerprint(T) || throw(FingerprintException(T))
end

# Decoding
function decode!(x::LCMType, io::IO)
    check_fingerprint(io, typeof(x))
    decodefield!(x, io)
end

"""
    decode_in_place(T)

Specify whether type `T` should be decoded in place, i.e. whether to use a
`decodefield!` method instead of a `decodefield` method.
"""
function decode_in_place end

Base.@pure decode_in_place(::Type{<:LCMType}) = true
@generated function decodefield!(x::T, io::IO) where T<:LCMType
    field_assignments = Vector{Expr}(fieldcount(x))
    for (i, fieldname) in enumerate(fieldnames(x))
        F = fieldtype(x, fieldname)
        field_assignments[i] = quote
            if decode_in_place($F)
                decodefield!(x.$fieldname, io)
            else
                x.$fieldname = decodefield(io, $F)
            end
            # $(QuoteNode(fieldname)) ∈ size_fields(T) && resize!(x) # allocates!
            any($(QuoteNode(fieldname)) .== size_fields(T)) && resize!(x)
        end
    end
    return quote
        $(field_assignments...)
        return x
    end
end

Base.@pure decode_in_place(::Type{Bool}) = false
decodefield(io::IO, ::Type{Bool}) = read(io, UInt8) == 0x01

Base.@pure decode_in_place(::Type{<:NETWORK_BYTE_ORDER_TYPES}) = false
decodefield(io::IO, ::Type{T}) where {T<:NETWORK_BYTE_ORDER_TYPES} = ntoh(read(io, T))

Base.@pure decode_in_place(::Type{String}) = false
function decodefield(io::IO, ::Type{String})
    len = ntoh(read(io, UInt32))
    ret = String(read(io, len - 1))
    read(io, UInt8) # strip off null
    ret
end

Base.@pure decode_in_place(::Type{<:Vector}) = true
function decodefield!(x::Vector{T}, io::IO) where T
    @inbounds for i in eachindex(x)
        if decode_in_place(T)
            isassigned(x, i) || (x[i] = default_value(T))
            decodefield!(x[i], io)
        else
            x[i] = decodefield(io, T)
        end
    end
    x
end

Base.@pure decode_in_place(::Type{SV}) where {SV<:StaticVector} = decode_in_place(eltype(SV))
function decodefield!(x::StaticVector, io::IO)
    decode_in_place(eltype(x)) || error()
    @inbounds for i in eachindex(x)
        decodefield!(x[i], io)
    end
    x
end
@generated function decodefield(io::IO, ::Type{SV}) where {N, T, SV<:StaticVector{N, T}}
    constructor_arg_exprs = [:(decodefield(io, T)) for i = 1 : N]
    return quote
        decode_in_place(T) && error()
        SV(tuple($(constructor_arg_exprs...)))
    end
end


# Encoding
"""
    encode(io::IO, x::LCMType)

Write an LCM byte representation of `x` to `io`.
"""
function encode(io::IO, x::LCMType)
    encodefield(io, fingerprint(typeof(x)))
    encodefield(io, x)
end

@generated function encodefield(io::IO, x::LCMType)
    encode_exprs = Vector{Expr}(fieldcount(x))
    for (i, fieldname) in enumerate(fieldnames(x))
        encode_exprs[i] = :(encodefield(io, x.$fieldname))
    end
    quote
        check_valid(x)
        $(encode_exprs...)
        io
    end
end

encodefield(io::IO, x::Bool) = write(io, ifelse(x, 0x01, 0x00))

encodefield(io::IO, x::NETWORK_BYTE_ORDER_TYPES) = write(io, hton(x))

function encodefield(io::IO, x::String)
    write(io, hton(UInt32(length(x) + 1)))
    write(io, x)
    write(io, UInt8(0))
end

function encodefield(io::IO, A::AbstractVector)
    for x in A
        encodefield(io, x)
    end
end

# Sugar
encode(data::Vector{UInt8}, x::LCMType) = encode(IOBuffer(data, false, true), x)
encode(x::LCMType) = (stream = IOBuffer(false, true); encode(stream, x); flush(stream); take!(stream))

decode!(x::LCMType, data::Vector{UInt8}) = decode!(x, BufferedInputStream(data))
decode(data::Vector{UInt8}, ::Type{T}) where {T<:LCMType} = decode!(T(), data)
