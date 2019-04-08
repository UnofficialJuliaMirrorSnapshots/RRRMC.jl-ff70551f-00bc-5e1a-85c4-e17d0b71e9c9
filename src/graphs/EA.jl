# This file is a part of RRRMC.jl. License is MIT: http://github.com/carlobaldassi/RRRMC.jl/LICENCE.md

module EA

using ExtractMacro
using ..Interface
using ..Common
using ..DFloats

using ...RRRMC # this is silly but it's required for correct cross-linking in docstrings, apparently

export GraphEA, GraphEANormalDiscretized, GraphEANormal

import ..Interface: energy, delta_energy, neighbors, allΔE,
                    update_cache!, update_cache_residual!

import ..DFloats: MAXDIGITS
sentinel(::Type{ET}) where {ET} = typemin(ET)

discr(::Type{ET}, x::Real) where {ET} = convert(ET, round(x, digits=MAXDIGITS))
discr(::Type{DFloat64}, x::Real) = x
discr(::Type{ET}, x::Integer) where {ET<:Integer} = convert(ET, x)

function gen_EA(L::Integer, D::Integer)
    L ≥ 2 || throw(ArgumentError("L must be ≥ 2, given: $L"))
    D ≥ 1 || throw(ArgumentError("D must be ≥ 0, given: $D"))
    N = L^D
    A = [Int[] for x = 1:N]
    dims = ntuple(d->L, D)

    for cind in CartesianIndices(dims)
        x = LinearIndices(dims)[cind.I...]
        for d in 1:D
            I1 = ntuple(k->(k==d ? mod1(cind.I[k] + 1, L) : cind.I[k]), D)
            y = LinearIndices(dims)[I1...]
            push!(A[x], y)
            push!(A[y], x)
        end
    end
    map!(sort!, A, A)
    tA = NTuple{2D,Int}[tuple(Ax...) for Ax in A]
    return tA
end

function gen_J(f, ET::Type, N::Integer, A::Vector{NTuple{twoD,Int}}) where {twoD}
    @assert all(issorted, A)
    m = sentinel(ET)
    J = Vector{ET}[zeros(ET,twoD) for i = 1:N]
    map(Jx->fill!(Jx, m), J)
    for x = 1:N
        Jx = J[x]
        Ax = A[x]
        for k = 1:length(Ax)
            y = Ax[k]
            if x < y
                Jxy = f()
                @assert Jx[k] == m
                Jx[k] = Jxy
                J[y][findfirst(==(m), J[y])] = Jxy
            # else # this check fails for L=2
            #     l = findfirst(A[y], x)
            #     Jxy = J[y][l]
            #     @assert Jxy ≠ m
            #     @assert J[x][k] == Jxy
            end
        end
    end
    @assert all(Jx->all(Jx .≠ m), J)
    tJ = NTuple{twoD,ET}[tuple(Jx...) for Jx in J]
    return tJ
end

function gen_AJ(fname::AbstractString)
    D = 2
    twoD = 2D
    f = open(fname)
    local N, L, A, J, tJ
    try
        @assert startswith(strip(readline(f)), "type:")
        ls = split(readline(f))
        @assert length(ls) == 2
        @assert ls[1] == "size:"
        L = parse(Int, ls[2])
        @assert startswith(strip(readline(f)), "name:")
        A = EA.gen_EA(L, D)
        N = length(A)

        m = EA.sentinel(Float64)
        J = Vector{Float64}[zeros(twoD) for i = 1:N]
        map(Jx->fill!(Jx, m), J)

        for l in eachline(f)
            ls = split(l)
            @assert length(ls) == 3
            x, y, Jxy = parse(Int, ls[1]), parse(Int, ls[2]), parse(Float64, ls[3])

            Jx = J[x]
            Ax = A[x]
            k = findfirst(Ax, y)
            @assert k ≠ 0
            @assert Jx[k] == m
            Jx[k] = Jxy

            Jy = J[y]
            Ay = A[y]
            k = findfirst(Ay, x)
            @assert k ≠ 0
            @assert Jy[k] == m
            Jy[k] = Jxy
        end
        @assert all(Jx->all(Jx .≠ m), J)
    finally
        close(f)
    end
    tJ = NTuple{twoD,Float64}[tuple(Jx...) for Jx in J]

    return L, D, A, tJ
end

function get_vLEV(LEV, ET::Type)
    LEV isa Tuple{Real,Vararg{Real}} || throw(ArgumentError("invalid level spec, expected a Tuple of Reals, given: $LEV"))
    length(unique(LEV)) == length(LEV) || throw(ArgumentError("repeated levels in LEV: $LEV"))

    vLEV = Array{ET}(undef, length(LEV))
    try
        for i = 1:length(LEV)
            vLEV[i] = LEV[i]
        end
    catch
        throw(ArgumentError("incompatible energy type and level spec, conversion failed, given: ET=$ET LEV=$LEV"))
    end
    m = sentinel(ET)
    m ∈ vLEV && throw(ArgumentError("illegal level value: $m"))
    any(x->discr(ET, x) ≠ x, vLEV) && throw(ArgumentError("up to $MAXDIGITS decimal digits supported in levels, given: $LEV"))
    return vLEV
end

mutable struct GraphEA{ET,LEV,twoD} <: DiscrGraph{ET}
    N::Int
    #L::Int
    A::Vector{NTuple{twoD,Int}}
    J::Vector{NTuple{twoD,ET}}
    uA::Vector{Vector{Int}}
    cache::LocalFields{ET}
    function GraphEA{ET,LEV,twoD}(A::Vector{NTuple{twoD,Int}}, J::Vector{NTuple{twoD,ET}}) where {ET,LEV,twoD}
        isa(twoD, Integer) || throw(ArgumentError("twoD must be integer, given a: $(typeof(twoD))"))
        iseven(twoD) || throw(ArgumentError("twoD must be even, given: $twoD"))
        D = twoD ÷ 2
        D ≥ 1 || throw(ArgumentError("D must be ≥ 0, given: $D"))

        N = length(A)
        N ≥ 2 || throw(ArgumentError("invalid A, expected length ≥ 2, found: $N"))
        all(a->length(a) == twoD, A) || throw(ArgumentError("invalid A inner length, expected $twoD, given: $(unique(map(length,A)))"))

        isL2 = (A[1][1] == A[1][2])
        all(a->(issorted(a) && unique(a) == collect(a[1:(1+isL2):end])), A) || throw(ArgumentError("invalid A, does not look like an EA graph"))

        uA = [collect(a[1:(1+isL2):end]) for a in A]

        vLEV = get_vLEV(LEV, ET)
        all(Jx->all(Jxy->Jxy ∈ vLEV, Jx), J) || throw(ArgumentError("the given J is incompatible with levels $LEV"))
        length(J) == N || throw(ArgumentError("incompatible lengths of A and J: $(length(A)), $(length(J))"))
        all(j->length(j) == twoD, J) || throw(ArgumentError("invalid J inner length, expected $twoD, given: $(unique(map(length,J)))"))

        cache = LocalFields{ET}(N)

        return new{ET,LEV,twoD}(N, A, J, uA, cache)
    end
end

"""
    GraphEA(L::Integer, D::Integer, LEV = (-1,1)) <: DiscrGraph

An Edwards-Anderson `DiscrGraph`: spins are arranged on a square lattice of size `L`
in `D` dimensions (i.e. there are \$L^D\$ total spins), with periodic boundary
conditions.

The interactions are extracted at random from `LEV`, which must be a `Tuple` of `Real`s.
No external fields.
"""
function GraphEA(L::Integer, D::Integer, LEV::Tuple{ET,Vararg{ET}}) where {ET<:Real}
    A = gen_EA(L, D)
    vLEV = get_vLEV(LEV, ET)
    N = length(A)
    J = gen_J(ET, N, A) do
        rand(vLEV)
    end
    return GraphEA{ET,LEV,2D}(A, J)
end
GraphEA(L::Integer, D::Integer, LEV::Tuple{Real,Vararg{Real}}) = GraphEA(L, D, promote(LEV...))
GraphEA(L::Integer, D::Integer) = GraphEA(L, D, (-1,1))

GraphEA(L::Integer, D::Integer, LEV::Tuple{Float64,Vararg{Float64}}) = GraphEA(L, D, map(DFloat64, LEV))

function energy(X::GraphEA{ET}, C::Config) where {ET}
    @assert X.N == C.N
    @extract C : s
    @extract X : A J cache
    @extract cache : lfields lfields_last
    n = zero(ET)
    for x = 1:length(A)
        Jx = J[x]
        σx = 2 * s[x] - 1
        Ax = A[x]
        lf = zero(ET)
        for k = 1:length(Ax)
            y = Ax[k]
            σy = 2 * s[y] - 1
            Jxy = Jx[k]

            lf -= Jxy * σx * σy
        end
        n += lf
        lfields[x] = discr(ET, 2lf)
    end
    #@assert n % 2 == 0
    #n ÷= 2
    n /= 2
    cache.move_last = 0
    fill!(lfields_last, zero(ET))
    return discr(ET, n)
end

function update_cache!(X::GraphEA{ET}, C::Config, move::Int) where {ET}
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N
    @extract C : N s
    @extract X : A uA J cache

    @extract cache : lfields lfields_last move_last
    if move_last == move
        @inbounds begin
            Ux = uA[move]
            for y in Ux
                lfields[y], lfields_last[y] = lfields_last[y], lfields[y]
            end
            lfields[move] = -lfields[move]
            lfields_last[move] = -lfields_last[move]
        end
        return
    end

    @inbounds begin
        Ux = uA[move]
        for y in Ux
            lfields_last[y] = lfields[y]
        end
        Jx = J[move]
        sx = s[move]
        Ax = A[move]
        for k = 1:length(Ax)
            y = Ax[k]
            σxy = 1 - 2 * (sx ⊻ s[y])
            Jxy = Jx[k]
            lfields[y] = discr(ET, lfields[y] - 4 * σxy * Jxy)
        end
        lfm = lfields[move]
        lfields_last[move] = lfm
        lfields[move] = -lfm
    end
    cache.move_last = move

    return
end

function delta_energy(X::GraphEA{ET}, C::Config, move::Int) where {ET}
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N
    #@extract C : s
    #@extract X : A J
    @extract X : cache
    @extract cache : lfields

    @inbounds Δ = -lfields[move]
    return Δ

    # @inbounds begin
    #     Δ = zero(ET)
    #     Jx = J[move]
    #     σx = 2 * s[move] - 1
    #     Ax = A[move]
    #     for k = 1:length(Ax)
    #         y = Ax[k]
    #         σy = 2 * s[y] - 1
    #         Jxy = Jx[k]
    #         Δ += 2 * Jxy * σx * σy
    #     end
    # end
    # return discr(ET, Δ)
end

neighbors(X::GraphEA, i::Int) = return X.uA[i]
@generated allΔE(::Type{GraphEA{Int,(-1,1),twoD}}) where {twoD} = Expr(:tuple, ntuple(d1->(4 * (d1 - 1)), (twoD÷2)+1)...)

@generated function allΔE(::Type{GraphEA{ET,LEV,twoD}}) where {ET,LEV,twoD}
    list = Set{ET}()
    L = length(LEV)
    es = Set{ET}(zero(ET))
    for n = 1:twoD
        newes = Set{ET}()
        for n in es, l in LEV
            push!(newes, discr(ET, n + l))
            push!(newes, discr(ET, n - l))
        end
        es = newes
    end
    deltas = sort!(unique((x->2 * abs(x)).(collect(es))))
    return Expr(:tuple, deltas...)
end

mutable struct GraphEANormalDiscretized{ET,LEV,twoD} <: DoubleGraph{DiscrGraph{ET},Float64}
    N::Int
    X0::GraphEA{ET,LEV,twoD}
    A::Vector{NTuple{twoD,Int}}
    rJ::Vector{NTuple{twoD,Float64}}
    uA::Vector{Vector{Int}}
    cache::LocalFields{Float64}
    function GraphEANormalDiscretized{ET,LEV,twoD}(L::Integer) where {ET,LEV,twoD}
        isa(twoD, Integer) || throw(ArgumentError("twoD must be integer, given a: $(typeof(twoD))"))
        iseven(twoD) || throw(ArgumentError("twoD must be even, given: $twoD"))
        D = twoD ÷ 2
        D ≥ 1 || throw(ArgumentError("D must be ≥ 0, given: $D"))
        A = gen_EA(L, D)
        N = length(A)
        cJ = gen_J(Float64, N, A) do
            randn()
        end

        dJ = Array{NTuple{twoD,ET}}(undef, N)
        rJ = Array{NTuple{twoD,Float64}}(undef, N)
        for (x, cJx) in enumerate(cJ)
            dJ[x], rJ[x] = discretize(cJx, LEV)
        end

        X0 = GraphEA{ET,LEV,twoD}(A, dJ)
        cache = LocalFields{Float64}(N)
        return new{ET,LEV,twoD}(N, X0, A, rJ, X0.uA, cache)
    end
end

"""
    GraphEANormalDiscretized(L::Integer, D::Integer, LEV) <: DoubleGraph{DiscrGraph,Float64}

An Edwards-Anderson `DoubleGraph`: spins are arranged on a square lattice of size `L`
in `D` dimensions (i.e. there are \$L^D\$ total spins), with periodic boundary
conditions.

The interactions are extracted at random from a normal distribution
with unit variance, and are then discretized using the values in `LEV`,
which must be a `Tuple` of `Real`s. No external fields.

Same as [`GraphEANormal`](@ref), but works differently when used with [`rrrMC`](@ref).
"""
GraphEANormalDiscretized(L::Integer, D::Integer, LEV::Tuple{ET,Vararg{ET}}) where {ET<:Real} = GraphEANormalDiscretized{ET,LEV,2D}(L)
GraphEANormalDiscretized(L::Integer, D::Integer, LEV::Tuple{Real,Vararg{Real}}) = GraphEANormalDiscretized(L, D, promote(LEV...))

GraphEANormalDiscretized(L::Integer, D::Integer, LEV::Tuple{Float64,Vararg{Float64}}) = GraphEANormalDiscretized{DFloat64,map(DFloat64,LEV),2D}(L)

function energy(X::GraphEANormalDiscretized, C::Config)
    @assert X.N == C.N
    @extract X : X0 A J=rJ cache
    @extract C : N s
    @extract cache : lfields lfields_last

    E0 = energy(X0, C)

    E1 = 0.0
    for x = 1:length(A)
        Jx = J[x]
        σx = 2 * s[x] - 1
        Ax = A[x]
        lf = 0.0
        for k = 1:length(Ax)
            y = Ax[k]
            σy = 2 * s[y] - 1
            Jxy = Jx[k]

            lf -= Jxy * σx * σy
        end
        E1 += lf
        lfields[x] = 2lf
    end
    E1 /= 2
    cache.move_last = 0
    fill!(lfields_last, 0.0)

    return convert(Float64, E0 + E1)
end

function update_cache!(X::GraphEANormalDiscretized{ET}, C::Config, move::Int) where {ET}
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N

    if X.cache.move_last ≠ X.X0.cache.move_last
        update_cache!(X.X0, C, move)
        update_cache_residual!(X, C, move)
        return
    end

    @extract C : N s
    @extract X : A uA rJ X0 cache
    @extract X0 : J0=J cache0=cache

    @extract cache : lfields lfields_last move_last
    @extract cache0 : lfields0=lfields lfields_last0=lfields_last move_last0=move_last
    @assert move_last0 == move_last
    if move_last == move
        @inbounds begin
            Ux = uA[move]
            for y in Ux
                lfields[y], lfields_last[y] = lfields_last[y], lfields[y]
                lfields0[y], lfields_last0[y] = lfields_last0[y], lfields0[y]
            end
            lfields[move] = -lfields[move]
            lfields_last[move] = -lfields_last[move]
            lfields0[move] = -lfields0[move]
            lfields_last0[move] = -lfields_last0[move]
        end
        return
    end

    @inbounds begin
        Ux = uA[move]
        for y in Ux
            lfields_last[y] = lfields[y]
            lfields_last0[y] = lfields0[y]
        end
        Jx0 = J0[move]
        Jx = rJ[move]
        sx = s[move]
        Ax = A[move]
        for k = 1:length(Ax)
            y = Ax[k]
            σxy = 1 - 2 * (sx ⊻ s[y])

            Jxy0 = Jx0[k]
            lfields0[y] = discr(ET, lfields0[y] - 4 * σxy * Jxy0)

            Jxy = Jx[k]
            lfields[y] -= 4 * σxy * Jxy
        end
        lfm0 = lfields0[move]
        lfields_last0[move] = lfm0
        lfields0[move] = -lfm0

        lfm = lfields[move]
        lfields_last[move] = lfm
        lfields[move] = -lfm
    end
    cache0.move_last = move
    cache.move_last = move

    return
end

function update_cache_residual!(X::GraphEANormalDiscretized, C::Config, move::Int)
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N
    @extract C : N s
    @extract X : A uA J=rJ cache

    @extract cache : lfields lfields_last move_last
    if move_last == move
        @inbounds begin
            Ux = uA[move]
            for y in Ux
                lfields[y], lfields_last[y] = lfields_last[y], lfields[y]
            end
            lfields[move] = -lfields[move]
            lfields_last[move] = -lfields_last[move]
        end
        return
    end

    @inbounds begin
        Ux = uA[move]
        for y in Ux
            lfields_last[y] = lfields[y]
        end
        Jx = J[move]
        sx = s[move]
        Ax = A[move]
        for k = 1:length(Ax)
            y = Ax[k]
            σxy = 1 - 2 * (sx ⊻ s[y])
            Jxy = Jx[k]
            lfields[y] -= 4 * σxy * Jxy
        end
        lfm = lfields[move]
        lfields_last[move] = lfm
        lfields[move] = -lfm
    end
    cache.move_last = move

    return
end

function delta_energy_residual(X::GraphEANormalDiscretized, C::Config, move::Int)
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N
    #@extract C : s
    @extract X : cache
    @extract cache : lfields

    @inbounds Δ = -lfields[move]
    return Δ

    # @inbounds begin
    #     Δ = 0.0
    #     Jx = J[move]
    #     σx = 2 * s[move] - 1
    #     Ax = A[move]
    #     for k = 1:length(Ax)
    #         y = Ax[k]
    #         σy = 2 * s[y] - 1
    #         Jxy = Jx[k]
    #         Δ += 2 * Jxy * σx * σy
    #     end
    # end
    # return Δ
end

function delta_energy(X::GraphEANormalDiscretized, C::Config, move::Int)
    ΔE0 = delta_energy(X.X0, C, move)
    ΔE1 = delta_energy_residual(X, C, move)
    return convert(Float64, ΔE0 + ΔE1)
end

neighbors(X::GraphEANormalDiscretized, i::Int) = return X.uA[i]


## GraphEANormal

mutable struct GraphEANormal{twoD} <: SimpleGraph{Float64}
    N::Int
    A::Vector{NTuple{twoD,Int}}
    J::Vector{NTuple{twoD,Float64}}
    uA::Vector{Vector{Int}}
    cache::LocalFields{Float64}
    function GraphEANormal{twoD}(L::Integer, A, J) where {twoD}
        isa(twoD, Integer) || throw(ArgumentError("twoD must be integer, given a: $(typeof(twoD))"))
        iseven(twoD) || throw(ArgumentError("twoD must be even, given: $twoD"))
        D = twoD ÷ 2
        D ≥ 1 || throw(ArgumentError("D must be ≥ 0, given: $D"))
        N = length(A)
        # TODO: check A and J

        uA = [unique(a) for a in A] # needed for the case L=2

        cache = LocalFields{Float64}(N)
        return new{twoD}(N, A, J, uA, cache)
    end
end

"""
    GraphEANormal(L::Integer, D::Integer) <: SimpleGraph{Float64}

An Edwards-Anderson `SimpleGraph`: spins are arranged on a square lattice of size `L`
in `D` dimensions (i.e. there are \$L^D\$ total spins), with periodic boundary
conditions.

Same as [`GraphEA`](@ref), but the interactions are extracted from a normal distribution
with unit variance.
"""
function GraphEANormal(L::Integer, D::Integer; genJf=randn)
    D ≥ 1 || throw(ArgumentError("D must be ≥ 0, given: $D"))
    A = gen_EA(L, D)
    N = length(A)
    J = gen_J(Float64, N, A) do
        genJf()
    end

    return GraphEANormal{2D}(L, A, J)
end

function GraphEANormal(fname::AbstractString)
    L, D, A, J = EA.gen_AJ(fname)
    N = length(A)
    @assert N == L^D
    return GraphEANormal{2D}(L, A, J)
end


function energy(X::GraphEANormal, C::Config)
    @assert X.N == C.N
    @extract X : A J cache
    @extract C : N s
    @extract cache : lfields lfields_last

    E1 = 0.0
    for x = 1:length(A)
        Jx = J[x]
        σx = 2 * s[x] - 1
        Ax = A[x]
        lf = 0.0
        for k = 1:length(Ax)
            y = Ax[k]
            σy = 2 * s[y] - 1
            Jxy = Jx[k]

            lf -= Jxy * σx * σy
        end
        E1 += lf
        lfields[x] = 2lf
    end
    E1 /= 2
    cache.move_last = 0
    fill!(lfields_last, 0.0)

    return E1
end

function update_cache!(X::GraphEANormal, C::Config, move::Int)
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N
    @extract C : N s
    @extract X : A uA J cache

    @extract cache : lfields lfields_last move_last
    if move_last == move
        @inbounds begin
            Ux = uA[move]
            for y in Ux
                lfields[y], lfields_last[y] = lfields_last[y], lfields[y]
            end
            lfields[move] = -lfields[move]
            lfields_last[move] = -lfields_last[move]
        end
        return
    end

    @inbounds begin
        Ux = uA[move]
        for y in Ux
            lfields_last[y] = lfields[y]
        end
        Jx = J[move]
        sx = s[move]
        Ax = A[move]
        for k = 1:length(Ax)
            y = Ax[k]
            σxy = 1 - 2 * (sx ⊻ s[y])
            Jxy = Jx[k]
            lfields[y] -= 4 * σxy * Jxy
        end
        lfm = lfields[move]
        lfields_last[move] = lfm
        lfields[move] = -lfm
    end
    cache.move_last = move

    return
end

function delta_energy(X::GraphEANormal, C::Config, move::Int)
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N
    #@extract C : s
    @extract X : cache
    @extract cache : lfields

    @inbounds Δ = -lfields[move]
    return Δ

    # @inbounds begin
    #     Δ = 0.0
    #     Jx = J[move]
    #     σx = 2 * s[move] - 1
    #     Ax = A[move]
    #     for k = 1:length(Ax)
    #         y = Ax[k]
    #         σy = 2 * s[y] - 1
    #         Jxy = Jx[k]
    #         Δ += 2 * Jxy * σx * σy
    #     end
    # end
    # return Δ
end

neighbors(X::GraphEANormal, i::Int) = return X.uA[i]

end
