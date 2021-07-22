"""
    GCNConv([fg,] in => out, σ=identity; bias=true, init=glorot_uniform)

Graph convolutional layer.

# Arguments

- `fg`: Optionally pass a [`FeaturedGraph`](@ref). 
- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `σ`: Activation function.
- `bias`: Add learnable bias.
- `init`: Weights' initializer.


The input to the layer is a node feature array `X` 
of size `(num_features, num_nodes)`.
"""
struct GCNConv{A<:AbstractMatrix, B, F, S<:AbstractFeaturedGraph} <: AbstractGraphLayer
    weight::A
    bias::B
    σ::F
    fg::S
end

function GCNConv(fg::AbstractFeaturedGraph, ch::Pair{Int,Int}, σ=identity;
                 init=glorot_uniform, bias::Bool=true)
    in, out = ch
    W = init(out, in)
    b = Flux.create_bias(W, bias, out)
    GCNConv(W, b, σ, fg)
end

GCNConv(ch::Pair{Int,Int}, σ = identity; kwargs...) =
    GCNConv(NullGraph(), ch, σ; kwargs...)

@functor GCNConv

function (l::GCNConv)(fg::FeaturedGraph, x::AbstractMatrix)
    L̃ = normalized_laplacian(fg, eltype(x); selfloop=true)
    l.σ.(l.weight * x * L̃ .+ l.bias)
end

(l::GCNConv)(fg::FeaturedGraph) = FeaturedGraph(fg, nf = l(fg, node_feature(fg)))

function Base.show(io::IO, l::GCNConv)
    out, in = size(l.weight)
    print(io, "GCNConv($in => $out")
    l.σ == identity || print(io, ", ", l.σ)
    print(io, ")")
end


"""
    ChebConv([fg,] in=>out, k; bias=true, init=glorot_uniform)

Chebyshev spectral graph convolutional layer.

# Arguments

- `fg`: Optionally pass a [`FeaturedGraph`](@ref). 
- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `k`: The order of Chebyshev polynomial.
- `bias`: Add learnable bias.
- `init`: Weights' initializer.
"""
struct ChebConv{A<:AbstractArray{<:Number,3}, B, S<:AbstractFeaturedGraph} <: AbstractGraphLayer
    weight::A
    bias::B
    fg::S
    k::Int
end

function ChebConv(fg::AbstractFeaturedGraph, ch::Pair{Int,Int}, k::Int;
                  init=glorot_uniform, bias::Bool=true)
    in, out = ch
    W = init(out, in, k)
    b = Flux.create_bias(W, bias, out)
    ChebConv(W, b, fg, k)
end

ChebConv(ch::Pair{Int,Int}, k::Int; kwargs...) =
    ChebConv(NullGraph(), ch, k; kwargs...)

@functor ChebConv

function (c::ChebConv)(fg::FeaturedGraph, X::AbstractMatrix{T}) where T
    check_num_nodes(fg, X)
    @assert size(X, 1) == size(c.weight, 2) "Input feature size must match input channel size."
    
    L̃ = scaled_laplacian(fg, eltype(X))    

    Z_prev = X
    Z = X * L̃
    Y = view(c.weight,:,:,1) * Z_prev
    Y += view(c.weight,:,:,2) * Z
    for k = 3:c.k
        Z, Z_prev = 2*Z*L̃ - Z_prev, Z
        Y += view(c.weight,:,:,k) * Z
    end
    return Y .+ c.bias
end

(l::ChebConv)(fg::FeaturedGraph) = FeaturedGraph(fg, nf = l(fg, node_feature(fg)))

function Base.show(io::IO, l::ChebConv)
    out, in, k = size(l.weight)
    print(io, "ChebConv(", in, " => ", out)
    print(io, ", k=", k)
    print(io, ")")
end


"""
    GraphConv([fg,] in => out, σ=identity, aggr=+; bias=true, init=glorot_uniform)

Graph neural network layer.

# Arguments

- `fg`: Optionally pass a [`FeaturedGraph`](@ref). 
- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `σ`: Activation function.
- `aggr`: An aggregate function applied to the result of message function. `+`, `-`,
`*`, `/`, `max`, `min` and `mean` are available.
- `bias`: Add learnable bias.
- `init`: Weights' initializer.
"""
struct GraphConv{V<:AbstractFeaturedGraph, A<:AbstractMatrix, B} <: MessagePassing
    fg::V
    weight1::A
    weight2::A
    bias::B
    σ
    aggr
end

function GraphConv(fg::AbstractFeaturedGraph, ch::Pair{Int,Int}, σ=identity, aggr=+;
                   init=glorot_uniform, bias::Bool=true)
    in, out = ch
    W1 = init(out, in)
    W2 = init(out, in)
    b = Flux.create_bias(W1, bias, out)
    GraphConv(fg, W1, W2, b, σ, aggr)
end

GraphConv(ch::Pair{Int,Int}, σ=identity, aggr=+; kwargs...) =
    GraphConv(NullGraph(), ch, σ, aggr; kwargs...)

@functor GraphConv

message(gc::GraphConv, x_i, x_j::AbstractVector, e_ij) = gc.weight2 * x_j

update(gc::GraphConv, m::AbstractVector, x::AbstractVector) = gc.σ.(gc.weight1*x .+ m .+ gc.bias)

function (gc::GraphConv)(fg::FeaturedGraph, x::AbstractMatrix)
    check_num_nodes(fg, x)
    _, x = propagate(gc, adjacency_list(fg), Fill(0.f0, 0, ne(fg)), x, +)
    x
end

(l::GraphConv)(fg::FeaturedGraph) = FeaturedGraph(fg, nf = l(fg, node_feature(fg)))

function Base.show(io::IO, l::GraphConv)
    in_channel = size(l.weight1, ndims(l.weight1))
    out_channel = size(l.weight1, ndims(l.weight1)-1)
    print(io, "GraphConv(", in_channel, " => ", out_channel)
    l.σ == identity || print(io, ", ", l.σ)
    print(io, ", aggr=", l.aggr)
    print(io, ")")
end



"""
    GATConv([fg,] in => out;
            heads=1,
            concat=true,
            init=glorot_uniform    
            bias=true, 
            negative_slope=0.2)

Graph attentional layer.

# Arguments

- `fg`: Optionally pass a [`FeaturedGraph`](@ref). 
- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `bias::Bool`: Keyword argument, whether to learn the additive bias.
- `heads`: Number attention heads 
- `concat`: Concatenate layer output or not. If not, layer output is averaged.
- `negative_slope::Real`: Keyword argument, the parameter of LeakyReLU.
"""
struct GATConv{V<:AbstractFeaturedGraph, T, A<:AbstractMatrix{T}, B} <: MessagePassing
    fg::V
    weight::A
    bias::B
    a::A
    negative_slope::T
    channel::Pair{Int, Int}
    heads::Int
    concat::Bool
end

function GATConv(fg::AbstractFeaturedGraph, ch::Pair{Int,Int};
                 heads::Int=1, concat::Bool=true, negative_slope=0.2f0,
                 init=glorot_uniform, bias::Bool=true)
    in, out = ch             
    W = init(out*heads, in)
    b = Flux.create_bias(W, bias, out*heads)
    a = init(2*out, heads)
    GATConv(fg, W, b, a, negative_slope, ch, heads, concat)
end

GATConv(ch::Pair{Int,Int}; kwargs...) = GATConv(NullGraph(), ch; kwargs...)

@functor GATConv

# Here the α that has not been softmaxed is the first number of the output message
function message(gat::GATConv, x_i::AbstractVector, x_j::AbstractVector)
    x_i = reshape(gat.weight*x_i, :, gat.heads)
    x_j = reshape(gat.weight*x_j, :, gat.heads)
    x_ij = vcat(x_i, x_j+zero(x_j))
    e = sum(x_ij .* gat.a, dims=1)  # inner product for each head, output shape: (1, gat.heads)
    e_ij = leakyrelu.(e, gat.negative_slope)
    vcat(e_ij, x_j)  # shape: (n+1, gat.heads)
end

# After some reshaping due to the multihead, we get the α from each message,
# then get the softmax over every α, and eventually multiply the message by α
function apply_batch_message(gat::GATConv, i, js, X::AbstractMatrix)
    e_ij = mapreduce(j -> GeometricFlux.message(gat, _view(X, i), _view(X, j)), hcat, js)
    n = size(e_ij, 1)
    αs = Flux.softmax(reshape(view(e_ij, 1, :), gat.heads, :), dims=2)
    msgs = view(e_ij, 2:n, :) .* reshape(αs, 1, :)
    reshape(msgs, (n-1)*gat.heads, :)
end

update_batch_edge(gat::GATConv, adj, E::AbstractMatrix, X::AbstractMatrix, u) = update_batch_edge(gat, adj, X)

function update_batch_edge(gat::GATConv, adj, X::AbstractMatrix)
    n = size(adj, 1)
    # a vertex must always receive a message from itself
    Zygote.ignore() do
        GraphLaplacians.add_self_loop!(adj, n)
    end
    mapreduce(i -> apply_batch_message(gat, i, adj[i], X), hcat, 1:n)
end

# The same as update function in batch manner
update_batch_vertex(gat::GATConv, M::AbstractMatrix, X::AbstractMatrix, u) = update_batch_vertex(gat, M)

function update_batch_vertex(gat::GATConv, M::AbstractMatrix)
    M = M .+ gat.bias
    if !gat.concat
        N = size(M, 2)
        M = reshape(mean(reshape(M, :, gat.heads, N), dims=2), :, N)
    end
    return M
end

function (gat::GATConv)(fg::FeaturedGraph, X::AbstractMatrix)
    check_num_nodes(fg, X)
    _, X = propagate(gat, adjacency_list(fg), Fill(0.f0, 0, ne(fg)), X, +)
    X
end

(l::GATConv)(fg::FeaturedGraph) = FeaturedGraph(fg, nf = l(fg, node_feature(fg)))

function Base.show(io::IO, l::GATConv)
    in_channel = size(l.weight, ndims(l.weight))
    out_channel = size(l.weight, ndims(l.weight)-1)
    print(io, "GATConv(", in_channel, "=>", out_channel)
    print(io, ", LeakyReLU(λ=", l.negative_slope)
    print(io, "))")
end


"""
    GatedGraphConv([fg,] out, num_layers; aggr=+, init=glorot_uniform)

Gated graph convolution layer.

# Arguments

- `fg`: Optionally pass a [`FeaturedGraph`](@ref). 
- `out`: The dimension of output features.
- `num_layers`: The number of gated recurrent unit.
- `aggr`: An aggregate function applied to the result of message function. `+`, `-`,
`*`, `/`, `max`, `min` and `mean` are available.
"""
struct GatedGraphConv{V<:AbstractFeaturedGraph, A<:AbstractArray{<:Number,3}, R} <: MessagePassing
    fg::V
    weight::A
    gru::R
    out_ch::Int
    num_layers::Int
    aggr
end

function GatedGraphConv(fg::AbstractFeaturedGraph, out_ch::Int, num_layers::Int;
                        aggr=+, init=glorot_uniform)
    w = init(out_ch, out_ch, num_layers)
    gru = GRUCell(out_ch, out_ch)
    GatedGraphConv(fg, w, gru, out_ch, num_layers, aggr)
end

GatedGraphConv(out_ch::Int, num_layers::Int; kwargs...) =
    GatedGraphConv(NullGraph(), out_ch, num_layers; kwargs...)

@functor GatedGraphConv

message(ggc::GatedGraphConv, x_i, x_j::AbstractVector, e_ij) = x_j

update(ggc::GatedGraphConv, m::AbstractVector, x) = m


function (ggc::GatedGraphConv)(fg::FeaturedGraph, H::AbstractMatrix{S}) where {T<:AbstractVector,S<:Real}
    check_num_nodes(fg, H)
    m, n = size(H)
    @assert (m <= ggc.out_ch) "number of input features must less or equals to output features."
    adj = adjacency_list(fg)
    if m < ggc.out_ch
        Hpad = similar(H, S, ggc.out_ch - m, n)
        H = vcat(H, fill!(Hpad, 0))
    end
    for i = 1:ggc.num_layers
        M = view(ggc.weight, :, :, i) * H
        _, M = propagate(ggc, adj, Fill(0.f0, 0, ne(fg)), M, +)
        H, _ = ggc.gru(H, M)  # BUG: FluxML/Flux.jl#1381
    end
    H
end

(l::GatedGraphConv)(fg::FeaturedGraph) = FeaturedGraph(fg, nf = l(fg, node_feature(fg)))


function Base.show(io::IO, l::GatedGraphConv)
    print(io, "GatedGraphConv(($(l.out_ch) => $(l.out_ch))^$(l.num_layers)")
    print(io, ", aggr=", l.aggr)
    print(io, ")")
end



"""
    EdgeConv([fg,] nn; aggr=max)

Edge convolutional layer.

# Arguments

- `fg`: Optionally pass a [`FeaturedGraph`](@ref). 
- `nn`: A neural network (e.g. a Dense layer or a MLP). 
- `aggr`: An aggregate function applied to the result of message function. `+`, `max` and `mean` are available.
"""
struct EdgeConv{V<:AbstractFeaturedGraph} <: MessagePassing
    fg::V
    nn
    aggr
end

EdgeConv(fg::AbstractFeaturedGraph, nn; aggr=max) = EdgeConv(fg, nn, aggr)
EdgeConv(nn; kwargs...) = EdgeConv(NullGraph(), nn; kwargs...)

@functor EdgeConv

message(ec::EdgeConv, x_i::AbstractVector, x_j::AbstractVector, e_ij) = ec.nn(vcat(x_i, x_j .- x_i))
update(ec::EdgeConv, m::AbstractVector, x) = m

function (ec::EdgeConv)(fg::FeaturedGraph, X::AbstractMatrix)
    check_num_nodes(fg, X)
    _, X = propagate(ec, adjacency_list(fg), Fill(0.f0, 0, ne(fg)), X, ec.aggr)
    X
end

(l::EdgeConv)(fg::FeaturedGraph) = FeaturedGraph(fg, nf = l(fg, node_feature(fg)))

function Base.show(io::IO, l::EdgeConv)
    print(io, "EdgeConv(", l.nn)
    print(io, ", aggr=", l.aggr)
    print(io, ")")
end


"""
    GINConv([fg,] nn, [eps])

    Graph Isomorphism Network.

# Arguments

- `fg`: Optionally pass in a FeaturedGraph as input.
- `nn`: A neural network/layer.
- `eps`: Weighting factor. Default 0.

The definition of this is as defined in the original paper,
Xu et. al. (2018) https://arxiv.org/abs/1810.00826.
"""
struct GINConv{V<:AbstractFeaturedGraph,R<:Real} <: MessagePassing
    fg::V
    nn
    eps::R
end

function GINConv(fg::AbstractFeaturedGraph, nn; eps=0f0)
    GINConv(fg, nn, eps)
end

function GINConv(nn; eps=0f0) 
    GINConv(NullGraph(), nn, eps)
end

Flux.trainable(g::GINConv) = (fg=g.fg,nn=g.nn)

message(g::GINConv, x_i::AbstractVector, x_j::AbstractVector) = x_j 
update(g::GINConv, m::AbstractVector, x) = g.nn((1 + g.eps) * x + m)

@functor GINConv

function (g::GINConv)(fg::FeaturedGraph, X::AbstractMatrix)
    gf = graph(fg)
    GraphSignals.check_num_node(gf, X)
    _, X = propagate(g, adjacency_list(gf), Fill(0.f0, 0, ne(gf)), X, +)
    X
end

(l::GINConv)(x::AbstractMatrix) = l(l.fg, x)
(l::GINConv)(fg::FeaturedGraph) = FeaturedGraph(fg.graph, nf = l(fg, node_feature(fg)))


"""
    CGConv([fg,] (node_dim, edge_dim), out, init)

Crystal Graph Convolutional network. Uses both node and edge features.

# Arguments

- `fg`: Optional [`FeaturedGraph`] argument(@ref)
- `node_dim`: Dimensionality of the input node features. Also is necessarily the output dimensionality.
- `edge_dim`: Dimensionality of the input edge features.
- `out`: Dimensionality of the output features.
- `init`: Initialization algorithm for each of the weight matrices
- `bias`: Whether or not to learn an additive bias parameter.

# Usage

You can call `CGConv` in several different ways:
                                    
- Pass a FeaturedGraph: `CGConv(fg)`, returns `FeaturedGraph` 
- Pass both node and edge features: `CGConv(X, E)` 
- Pass one matrix, which can either be node features or edge features: `CGConv(M; edge)`:
    `edge` is default false, meaning that `M` denotes node features.
"""
struct CGConv{V <: AbstractFeaturedGraph, T,
              A <: AbstractMatrix{T}, B} <: MessagePassing
    fg::V
    Wf::A
    Ws::A
    bf::B
    bs::B
end

@functor CGConv

function CGConv(fg::AbstractFeaturedGraph, dims::NTuple{2,Int};
                init=glorot_uniform, bias=true)
    node_dim, edge_dim = dims
    Wf = init(node_dim, 2*node_dim + edge_dim)
    Ws = init(node_dim, 2*node_dim + edge_dim)
    bf = Flux.create_bias(Wf, bias, node_dim)
    bs = Flux.create_bias(Ws, bias, node_dim)
    CGConv(fg, Wf, Ws, bf, bs)
end

function CGConv(dims::NTuple{2,Int}; init=glorot_uniform, bias=true)
    CGConv(NullGraph(), dims; init=init, bias=bias)
end

message(c::CGConv,
        x_i::AbstractVector, x_j::AbstractVector, e::AbstractVector) = begin
    z = vcat(x_i, x_j, e)
    σ.(c.Wf * z + c.bf) .* softplus.(c.Ws * z + c.bs)
end
update(c::CGConv, m::AbstractVector, x) = x + m

function (c::CGConv)(fg::FeaturedGraph, X::AbstractMatrix, E::AbstractMatrix)
    check_num_nodes(fg, X)
    check_num_edges(fg, E)
    _, Y = propagate(c, adjacency_list(fg), E, X, +)
    Y
end

(l::CGConv)(fg::FeaturedGraph) = FeaturedGraph(fg, nf=l(fg, node_feature(fg),
                                                        edge_feature(fg)),
                                               ef=edge_feature(fg))
(l::CGConv)(M::AbstractMatrix; as_edge=false) =
    if as_edge
        l(l.fg, node_feature(l.fg), M)
    else
        l(l.fg, M, edge_feature(l.fg))
    end
(l::CGConv)(X::AbstractMatrix, E::AbstractMatrix) = l(l.fg, X, E)
