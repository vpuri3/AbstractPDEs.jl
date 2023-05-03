using Adapt
using Functors
using SparseArrays

abstract type DeviceAdaptor end
struct CPUAdaptor <: DeviceAdaptor end
struct CUDAAdaptor <: DeviceAdaptor end

## CPU adaptor

Adapt.adapt_storage(::CPUAdaptor, x::AbstractArray) = adapt(Array, x)
function Adapt.adapt_storage(::CPUAdaptor, x::Union{AbstractRange, SparseArrays.AbstractSparseArray},)
    x
end

_isbitsarray(::AbstractArray{<:Number}) = true
_isbitsarray(::AbstractArray{T}) where{T} = isbitstype(T)
_isbitsarray(x) = false

_isleaf(x) = _isbitsarray(x) || Functors.isleaf(x)

"""
    cpu(x)

Transfer `x` to CPU
"""
function cpu end

cpu(x) = fmap(x -> adapt(CPUAdaptor(), x), x)

"""
    gpu(x)

Transfer `x` to GPU
"""
function gpu end

function gpu(x)
    if isnothing(USE_CUDA[])
        @warn "CUDA is not loaded."
        return x
    end

    if USE_CUDA[]
        return fmap(x -> adapt(CUDAAdaptor(), x), x; exclude=_isleaf)
    else
        @warn "CUDA loaded but not CUDA.functional() = false"
        return x
    end
end
