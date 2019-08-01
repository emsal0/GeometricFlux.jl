struct GCNConv{T,F}
    weight::AbstractMatrix{T}
    bias::AbstractMatrix{T}
    norm::AbstractMatrix{T}
    σ::F
end

function GCNConv(adj::AbstractMatrix, ch::Pair{<:Integer,<:Integer}, σ = identity;
                 init = glorot_uniform, T::DataType=Float32, bias::Bool=true)
    N = size(adj, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    GCNConv(param(init(ch[1], ch[2])), b, normalized_laplacian(adj+I, T), σ)
end

@treelike GCNConv

(g::GCNConv)(X::AbstractMatrix) = g.σ.(g.norm * X * g.weight + g.bias)



struct ChebConv{T}
    weight::AbstractArray{T,3}
    bias::AbstractMatrix{T}
    L̃::AbstractMatrix{T}
    k::Integer
    in_channel::Integer
    out_channel::Integer
end

function ChebConv(adj::AbstractMatrix, ch::Pair{<:Integer,<:Integer}, k::Integer;
                  init = glorot_uniform, T::DataType=Float32, bias::Bool=true)
    N = size(adj, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    L̃ = T(2. / eigmax(adj)) * normalized_laplacian(adj, T) - I
    ChebConv(param(init(k, ch[1], ch[2])), b, L̃, k, ch[1], ch[2])
end

@treelike ChebConv

function (c::ChebConv)(X::AbstractMatrix)
    fin = c.in_channel
    @assert size(X, 2) == fin "Input feature size must match input channel size."
    N = size(c.L̃, 1)
    @assert size(X, 1) == N "Input vertex number must match Laplacian matrix size."
    fout = c.out_channel

    T = eltype(X)
    Y = Array{T}(undef, N, fout)
    Z = Array{T}(undef, N, c.k, fin)
    for j = 1:fout
        Z[:,1,:] = X
        Z[:,2,:] = c.L̃ * X
        for k = 3:c.k
            Z[:,k,:] = 2*c.L̃* view(Z, :, k-1, :) - view(Z, :, k-2, :)
        end

        y = view(Z, :, :, 1) * view(c.weight, :, 1, j)
        for i = 2:fin
            y += view(Z, :, :, i) * view(c.weight, :, i, j)
        end
        Y[:,j] = y
    end
    Y += c.bias
    return Y
end



struct GraphConv{V,T} <: MessagePassing
    adjlist::V
    weight1::AbstractMatrix{T}
    weight2::AbstractMatrix{T}
    bias::AbstractMatrix{T}
    aggr::Symbol
end

function GraphConv(el::AbstractVector{<:AbstractVector{<:Integer}},
                   ch::Pair{<:Integer,<:Integer}, aggr=:add;
                   init = glorot_uniform, bias::Bool=true)
    N = size(el, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    GraphConv(el, param(init(ch[1], ch[2])), param(init(ch[1], ch[2])), b, aggr)
end

function GraphConv(adj::AbstractMatrix, ch::Pair{<:Integer,<:Integer}, aggr=:add;
                   init = glorot_uniform, bias::Bool=true)
    N = size(adj, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    GraphConv(neighbors(adj), param(init(ch[1], ch[2])), param(init(ch[1], ch[2])), b, aggr)
end

@treelike GraphConv

message(g::GraphConv; x_i=zeros(0), x_j=zeros(0)) = g.weight2' * x_j
update(g::GraphConv; X=zeros(0), M=zeros(0)) = X*g.weight1 + M + g.bias
(g::GraphConv)(X::AbstractMatrix) = propagate(g, X=X, aggr=:add)



struct GATConv{V,T} <: MessagePassing
    adjlist::V
    weight::AbstractMatrix{T}
    bias::AbstractMatrix{T}
    a::AbstractArray
    negative_slope::Real
end

function GATConv(adj::AbstractMatrix, ch::Pair{<:Integer,<:Integer}; heads=1,
                 concat=true, negative_slope=0.2, init=glorot_uniform, bias::Bool=true)
    N = size(adj, 1)
    b = bias ? param(init(N, ch[2])) : zeros(T, N, ch[2])
    GATConv(neighbors(adj), param(init(ch[1], ch[2])), b, param(init(2 * ch[2])), negative_slope)
end

@treelike GATConv

function message(g::GATConv; x_i=zeros(0), x_j=zeros(0))
    n = size(x_j, 2)
    α = leakyrelu.(g.a' * vcat(repeat(x_i, outer=(1,n)), x_j), g.negative_slope)
    α = asoftmax(α)
    α .* x_j
end
update(g::GATConv; X=zeros(0), M=zeros(0)) = M + g.bias
(g::GATConv)(X::AbstractMatrix) = propagate(g, X=X * g.weight, aggr=:add)


function asoftmax(xs)
    xs = [exp.(x) for x in xs]
    s = sum(xs)
    return [x ./ s for x in xs]
end



struct GatedGraphConv{V,T,R} <: MessagePassing
    adjlist::V
    weight::AbstractArray{T}
    gru::R
    out_ch::Integer
    num_layers::Integer
    aggr::Symbol
end

function GatedGraphConv(adj::AbstractMatrix, out_ch::Integer, num_layers::Integer;
                        aggr=:add, init=glorot_uniform)
    N = size(adj, 1)
    w = param(init(out_ch, out_ch, num_layers))
    gru = GRUCell(out_ch, out_ch)
    GatedGraphConv(neighbors(adj), w, gru, out_ch, num_layers, aggr)
end

@treelike GatedGraphConv

message(g::GatedGraphConv; x_i=zeros(0), x_j=zeros(0)) = x_j
update(g::GatedGraphConv; X=zeros(0), M=zeros(0)) = M
function (g::GatedGraphConv)(X::AbstractMatrix)
    H = X
    m, n = size(H)
    T = eltype(H)
    @assert (n <= g.out_ch) "number of input features must less or equals to output features."
    (n < g.out_ch) && (H = hcat(H, zeros(T, m, g.out_ch - n)))

    for i = 1:g.num_layers
        M = H * view(g.weight, :, :, i)
        M = propagate(g, X=M, aggr=g.aggr)
        H, _ = g.gru(H', M')
        H = H'
    end
    H
end



struct EdgeConv{V} <: MessagePassing
    adjlist::V
    nn
    aggr::Symbol
end

function EdgeConv(adj::AbstractMatrix, nn; aggr::Symbol=:max)
    EdgeConv(neighbors(adj), nn, aggr)
end

@treelike EdgeConv

function message(e::EdgeConv; x_i=zeros(0), x_j=zeros(0))
    n = size(x_j, 2)
    e.nn(vcat(repeat(x_i, outer=(1,n)), x_j .- x_i))
end
update(e::EdgeConv; X=zeros(0), M=zeros(0)) = M
(e::EdgeConv)(X::AbstractMatrix) = propagate(e, X=X, aggr=e.aggr)