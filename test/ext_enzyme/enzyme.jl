using Test
using Flux

using Enzyme: Enzyme, make_zero, Active, Duplicated, ReverseWithPrimal

using Functors
using FiniteDifferences


function gradient_fd(f, x...)
    f = f |> f64
    x = [cpu(x) for x in x]
    ps_and_res = [x isa AbstractArray ? (x, identity) : Flux.destructure(x) for x in x]
    ps = [f64(x[1]) for x in ps_and_res]
    res = [x[2] for x in ps_and_res]
    fdm = FiniteDifferences.central_fdm(5, 1)
    gs = FiniteDifferences.grad(fdm, (ps...) -> f((re(p) for (p,re) in zip(ps, res))...), ps...)
    return ((re(g) for (re, g) in zip(res, gs))...,)
end

function gradient_ez(f, x...)
    args = []
    for x in x
        if x isa Number
            push!(args, Active(x))
        else
            push!(args, Duplicated(x, make_zero(x)))
        end
    end
    ret = Enzyme.autodiff(ReverseWithPrimal, f, Active, args...)
    g = ntuple(i -> x[i] isa Number ? ret[1][i] : args[i].dval, length(x))
    return g
end

function test_grad(g1, g2; broken=false)
    fmap_with_path(g1, g2) do kp, x, y
        :state ∈ kp && return # ignore RNN and LSTM state
        if x isa AbstractArray{<:Number}
            # @show kp
            @test x ≈ y rtol=1e-2 atol=1e-6 broken=broken
        end
        return x
    end
end

function test_enzyme_grad(loss, model, x)
    Flux.trainmode!(model)
    l = loss(model, x)
    @test loss(model, x) == l # Check loss doesn't change with multiple runs

    grads_fd = gradient_fd(loss, model, x) |> cpu
    grads_flux = Flux.gradient(loss, model, x) |> cpu
    grads_enzyme = gradient_ez(loss, model, x) |> cpu

    # test_grad(grads_flux, grads_enzyme)
    test_grad(grads_fd, grads_enzyme)
end

@testset "gradient_ez" begin
    @testset "number and arrays" begin
        f(x, y) = sum(x.^2) + y^3
        x = Float32[1, 2, 3]
        y = 3f0
        g = gradient_ez(f, x, y)
        @test g[1] isa Array{Float32}
        @test g[2] isa Float32
        @test g[1] ≈ 2x
        @test g[2] ≈ 3*y^2
    end

    @testset "struct" begin
        struct SimpleDense{W, B, F}
            weight::W
            bias::B
            σ::F
        end
        SimpleDense(in::Integer, out::Integer; σ=identity) = SimpleDense(randn(Float32, out, in), zeros(Float32, out), σ)
        (m::SimpleDense)(x) = m.σ.(m.weight * x .+ m.bias)
        @functor SimpleDense

        model = SimpleDense(2, 4)
        x = randn(Float32, 2)
        loss(model, x) = sum(model(x))

        g = gradient_ez(loss, model, x)
        @test g[1] isa SimpleDense
        @test g[2] isa Array{Float32}
        @test g[1].weight isa Array{Float32}
        @test g[1].bias isa Array{Float32}
        @test g[1].weight ≈ ones(Float32, 4, 1) .* x'
        @test g[1].bias ≈ ones(Float32, 4)
    end
end

@testset "Models" begin
    function loss(model, x)
        sum(model(x))
    end

    models_xs = [
        (Dense(2=>4), randn(Float32, 2), "Dense"),
        (Chain(Dense(2=>4, tanh), Dense(4=>3)), randn(Float32, 2), "Chain(Dense, Dense)"),
        (f64(Chain(Dense(2=>4), Dense(4=>2))), randn(Float64, 2, 1), "f64(Chain(Dense, Dense))"),
        (Flux.Scale([1.0f0 2.0f0 3.0f0 4.0f0], true, abs2), randn(Float32, 2), "Flux.Scale"),
        (Conv((3, 3), 2 => 3), randn(Float32, 3, 3, 2, 1), "Conv"),
        (Chain(Conv((3, 3), 2 => 3, ), Conv((3, 3), 3 => 1, tanh)), rand(Float32, 5, 5, 2, 1), "Chain(Conv, Conv)"),
        # (Chain(Conv((4, 4), 2 => 2, pad=SamePad()), MeanPool((5, 5), pad=SamePad())), rand(Float32, 5, 5, 2, 2), "Chain(Conv, MeanPool)"),
        (Maxout(() -> Dense(5 => 4, tanh), 3), randn(Float32, 5, 1), "Maxout"),
        (SkipConnection(Dense(2 => 2), vcat), randn(Float32, 2, 3), "SkipConnection"),
        # (Flux.Bilinear((2, 2) => 3), randn(Float32, 2, 1), "Bilinear"),        
        (ConvTranspose((3, 3), 3 => 2, stride=2), rand(Float32, 5, 5, 3, 1), "ConvTranspose"),
    ]
    
    for (model, x, name) in models_xs
        @testset "check grad $name" begin
            println("testing $name")
            test_enzyme_grad(loss, model, x)
        end
    end
end

@testset "Recurrence Tests" begin
    function loss(model, x)
        for i in 1:3
            x = model(x)
        end
        return sum(x)
    end

    struct LSTMChain
        rnn1
        rnn2
    end
    function (m::LSTMChain)(x)
        st = m.rnn1(x)
        st = m.rnn2(st[1])
        return st[1]
    end

    models_xs = [
        # (RNN(3 => 2), randn(Float32, 3, 2), "RNN"), 
        # (LSTM(3 => 5), randn(Float32, 3, 2), "LSTM"),
        # (GRU(3 => 5), randn(Float32, 3, 10), "GRU"),
        # (Chain(RNN(3 => 4), RNN(4 => 3)), randn(Float32, 3, 2), "Chain(RNN, RNN)"),
        # (LSTMChain(LSTM(3 => 5), LSTM(5 => 3)), randn(Float32, 3, 2), "LSTMChain(LSTM, LSTM)"),
    ]

    for (model, x, name) in models_xs
        @testset "check grad $name" begin
            println("testing $name")
            test_enzyme_grad(loss, model, x)
        end
    end
end
