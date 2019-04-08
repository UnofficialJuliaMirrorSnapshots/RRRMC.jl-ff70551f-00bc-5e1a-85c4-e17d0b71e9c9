# This file is a part of RRRMC.jl. License is MIT: http://github.com/carlobaldassi/RRRMC.jl/LICENCE.md

module SAT

using Random
using ExtractMacro
using ..Interface
using ..Common

using ...RRRMC # this is silly but it's required for correct cross-linking in docstrings, apparently

export GraphSAT

import ..Interface: energy, delta_energy, neighbors, allΔE,
                    delta_energy_residual, update_cache!, update_cache_residual!

function choose(N::Int, K::Int)
    out = fill(typemax(Int), K)
    @inbounds for k = 1:K
        out[k] = rand(1:(N-k+1))
        for l = 1:(k-1)
            if out[l] ≤ out[k]
                out[k] += 1
            end
        end
        for l = 1:(k-1)
            if out[l] > out[k]
                x = out[k]
                for j = k:-1:l+1
                    out[j] = out[j-1]
                end
                out[l] = x
                break
            end
        end
    end
    #@assert issorted(out)
    #@assert all(diff(out) .≠ 0)
    return out
end

function gen_randomKSAT(N::Integer, K::Integer, α::Real)
    N > 0 || throw(ArgumentError("N must be positive: $N"))
    K > 0 || throw(ArgumentError("K must be positive: $K"))
    α ≥ 0 || throw(ArgumentError("α must be non-negative: $α"))
    N ≥ K || throw(ArgumentError("N must not be less than K: $N < $K"))

    M = round(Int, α * N)
    A = Array{IVec}(undef, M)
    J = [BitArray(undef, K) for a = 1:M]
    for a = 1:M
        A[a] = choose(N, K)
        rand!(J[a])
    end
    return A, J
end

struct ClauseCache
    M::Int
    S::IVec  # S[a] = how many vars satisfy clause a
    I::IVec2 # I[a] = indices of the vars in S[a]
    ClauseCache(M::Integer, K::Integer) = new(M, zeros(Int, M), IVec[zeros(Int, K) for a = 1:M])
    ClauseCache(M::Integer, A::IVec2) = new(M, zeros(Int, M), IVec[zeros(Int, length(A[a])) for a = 1:M])
end

function clear!(cache::ClauseCache)
    @extract cache : S I
    fill!(S, 0)
    for Ia in I
        fill!(Ia, 0)
    end
    return cache
end

struct GraphSAT <: DiscrGraph{Int}
    N::Int
    M::Int
    K::Int
    A::IVec2
    J::Vector{BitVector}
    T::IVec2
    neighb::IVec2
    max_conn::Int
    cache::ClauseCache
    lfcache::LocalFields{Int}
    function GraphSAT(N::Integer, A::IVec2, J::Vector{BitVector})
        M = length(A)
        length(J) == M || throw(ArgumentError("Incompatible lengths of A and J: $M vs $(length(J))"))

        K = maximum(map(length, A))

        T = [Int[] for i = 1:N]
        for a = 1:M
            for i in A[a]
                push!(T[i], a)
            end
        end

        neighb = [Int[] for i = 1:N]
        for i in 1:N
            Ti = T[i]
            for a in Ti, j in A[a]
                if j ≠ i && j ∉ neighb[i]
                    push!(neighb[i], j)
                end
            end
        end

        # TODO: more input consistency checks?
        max_conn = maximum(map(length, T))
        cache = ClauseCache(M, A)
        lfcache = LocalFields{Int}(N)
        return new(N, M, K, A, J, T, neighb, max_conn, cache, lfcache)
    end
end

"""
  GraphSAT(N::Integer, α::Real, K::Integer)

A `DiscrGraph` implementing a random `K`-SAT graph with `N` spins and `αN` clauses.

The energy of the model is the number of violated clauses.
"""
function GraphSAT(N::Integer, K::Integer, α::Real)
    A, J = gen_randomKSAT(N, K, α)
    return GraphSAT(N, A, J)
end

function export_cnf(X::GraphSAT, filename::AbstractString)
    @extract X : N M A J
    open(filename, "w") do f
        println(f, "p cnf $N $M")
        for a = 1:M
            for (j,i) in zip(J[a],A[a])
                print(f, (2j-1) * i, " ")
            end
            println(f, "0")
        end
    end
end

function export_cnf(X::GraphSAT, filename::AbstractString, decimate::Vector{Int})
    @extract X : N M A=deepcopy(A) J=deepcopy(J) T=deepcopy(T)

    j = 1
    while j ≤ length(decimate)
        v = decimate[j]
        s = v > 0
        i = abs(v)
        for a in T[i]
            isempty(A[a]) && continue
            k = findfirst(==(i), A[a])
            @assert k ≢ nothing
            if J[a][k] == s
                empty!(A[a])
            else
                length(A[a]) > 1 || @error("contradiction")
                deleteat!(A[a], k)
                deleteat!(J[a], k)
                if length(A[a]) == 1
                    newv = A[a][1] * (2J[a][1]-1)
                    -newv ∈ decimate && @error("contradiction")
                    newv ∉ decimate && push!(decimate, newv)
                    empty!(A[a])
                end
            end
        end
        empty!(T[i])
        j += 1
    end

    nM = sum(map(x->!isempty(x),A)) + length(decimate)

    open(filename, "w") do f
        println(f, "p cnf $N $nM")
        for a = 1:M
            isempty(A[a]) && continue
            for (j,i) in zip(J[a],A[a])
                print(f, (2j-1) * i, " ")
            end
            println(f, "0")
        end
        for v in decimate
            println(f, "$v 0")
        end
    end
end

function energy(X::GraphSAT, C::Config)
    length(C) == X.N || throw(ArgumentError("different N: $(length(C)) $(X.N)"))
    @extract C : s
    @extract X : N M A J T cache lfcache
    clear!(cache)
    @extract cache : S I
    @extract lfcache : lfields lfields_last

    n = 0
    @inbounds for a = 1:M
        Ja = J[a]
        Aa = A[a]
        sat = 0
        Ia = I[a]
        for k = 1:length(Aa)
            i = Aa[k]
            si = s[i]
            Ji = Ja[k]
            Ji ⊻ si == 0 && (sat += 1; Ia[sat] = i)
        end
        S[a] = sat
        sat == 0 && (n += 1)
    end

    for i = 1:N
        Δ = 0
        @inbounds for a in T[i]
            Sa = S[a]
            Ia = I[a]
            if Sa == 1 && (Ia[1] == i)
                Δ += 1
            elseif S[a] == 0
                Δ -= 1
            end
        end
        lfields[i] = -Δ
    end

    lfcache.move_last = 0
    fill!(lfields_last, 0)

    return n
end

function delta_energy(X::GraphSAT, C::Config, move::Int)
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N
    #@extract C : s
    @extract X : lfcache
    @extract lfcache : lfields

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

function update_cache!(X::GraphSAT, C::Config, move::Int)
    @assert X.N == C.N
    @assert 1 ≤ move ≤ C.N
    @extract C : N s
    @extract X : A T neighb cache lfcache

    @extract cache : S I
    @extract lfcache : lfields lfields_last move_last

    # if move_last == move
    #     @inbounds begin
    #         for j in neighbors[move]
    #             lfields[j], lfields_last[j] = lfields_last[j], lfields[j]
    #         end
    #         lfields[move] = -lfields[move]
    #         lfields_last[move] = -lfields_last[move]
    #     end
    #     return
    # end

    @inbounds for a in T[move]
        Sa = S[a]
        Ia = I[a]
        Aa = A[a]
        if Sa == 0
            S[a] = 1
            Ia[1] = move
            lfields[move] -= 2
            for j in Aa
                j == move && continue
                lfields[j] -= 1
            end
        else
            k = findfirst(==(move), Ia)
            if k ≢ nothing
                for l = k:Sa-1
                    Ia[l] = Ia[l+1]
                end
                Ia[Sa] = 0
                S[a] = Sa - 1
                if Sa == 1
                    lfields[move] += 2
                    for j in Aa
                        j == move && continue
                        lfields[j] += 1
                    end
                elseif Sa == 2
                    lfields[Ia[1]] -= 1
                end
            else
                if Sa == 1
                    lfields[Ia[1]] += 1
                end
                S[a] = Sa + 1
                Ia[Sa + 1] = move
            end
        end
    end

    # cache.move_last = move

    return
end

neighbors(X::GraphSAT, i::Int) = return X.neighb[i]

# TODO: improve
allΔE(X::GraphSAT) = tuple(0:X.max_conn...)

end
