# Test layers and data/model movements on and off the GPU
# Add tests for layers and their gradients on the GPU
# Most of the forward passes should be fine being applied
# to bitstype objects, but this gives higher coverage for our use-cases
# Check that getting the gradients does not throw

# generic movement tests
@testset "Basic GPU Movement" begin
  @test gradient(x -> sum(gpu(x)), rand(3,3)) isa Tuple
  @test gradient(x -> sum(cpu(x)), gpu(rand(3,3))) isa Tuple
end

# TODO: These layers get into scalar indexing
# `AlphaDropout` throws a compilation error on GPUs,
# whereas, the rest are scalar indexing issues.
const BROKEN_LAYERS = Union{DepthwiseConv,
                            AlphaDropout,
                            InstanceNorm,
                            GroupNorm}

function gpu_gradtest(name::String, layers::Vector, x_cpu=nothing, args...; test_cpu=true)
  isnothing(x_cpu) && error("Missing input to test the layers against.")
  @testset "$name GPU grad tests" begin
    for layer in layers
      @testset "$layer GPU grad test" begin

        # compute output and grad of parameters
        l_cpu = layer(args...)
        ps_cpu = Flux.params(l_cpu)
        y_cpu, back_cpu = pullback(() -> sum(l_cpu(x_cpu)), ps_cpu)
        gs_cpu = back_cpu(1f0)

        x_gpu = gpu(x_cpu)
        l_gpu = l_cpu |> gpu
        ps_gpu = Flux.params(l_gpu)

        if l_gpu isa BROKEN_LAYERS
          @test_broken gradient(() -> sum(l_gpu(x_gpu)), ps_gpu) isa Flux.Zygote.Grads
        else
          y_gpu, back_gpu = pullback(() -> sum(l_gpu(x_gpu)), ps_gpu)
          gs_gpu = back_gpu(1f0) # TODO many layers error out when backprop int 1, should fix

          # compute grad of input
          xg_cpu = gradient(x -> sum(l_cpu(x)), x_cpu)[1]
          xg_gpu = gradient(x -> sum(l_gpu(x)), x_gpu)[1]

          # test 
          if test_cpu
            @test y_gpu ≈ y_cpu   rtol=1e-4 atol=1e-4
            @test Array(xg_gpu) ≈ xg_cpu   rtol=1e-4 atol=1e-4
          end
          @test gs_gpu isa Flux.Zygote.Grads
          for (p_cpu, p_gpu) in zip(ps_cpu, ps_gpu)
            @test gs_gpu[p_gpu] isa Flux.CUDA.CuArray
            if test_cpu
              @test Array(gs_gpu[p_gpu]) ≈ gs_cpu[p_cpu]   rtol=1e-4 atol=1e-4
            end
          end
        end
      end
    end
  end
end


# Just to give testset in gradtest meaningful labels
ConvNoBias(args...) = Conv(args...; bias=false)
ConvTransposeNoBias(args...) = ConvTranspose(args...; bias=false)
CrossCorNoBias(args...) = CrossCor(args...; bias=false)
DepthwiseConvNoBias(args...) = DepthwiseConv(args...;bias=false)
r = rand(Float32, 28, 28, 1, 1)
conv_layers = [Conv, ConvNoBias, ConvTranspose, ConvTransposeNoBias, CrossCor, CrossCorNoBias, DepthwiseConv, DepthwiseConvNoBias]
gpu_gradtest("Conv", conv_layers, r, (2,2), 1=>3)

pooling_layers = [MaxPool, MeanPool]
gpu_gradtest("Pooling", pooling_layers, r, (2,2))

adaptive_pooling_layers = [AdaptiveMaxPool, AdaptiveMeanPool]
gpu_gradtest("AdaptivePooling", adaptive_pooling_layers, r, (7,7))

dropout_layers = [Dropout, AlphaDropout]
gpu_gradtest("Dropout", dropout_layers, r, 0.5f0; test_cpu=false) # dropout is not deterministic

layer_norm = [LayerNorm]
gpu_gradtest("LayerNorm 1", layer_norm, rand(Float32, 28,28,3,4), 1, test_cpu=false) #TODO fix errors
gpu_gradtest("LayerNorm 2", layer_norm, rand(Float32, 5,4), 5)

batch_norm = [BatchNorm]
gpu_gradtest("BatchNorm 1", batch_norm, rand(Float32, 28,28,3,4), 3, test_cpu=false) #TODO fix errors
gpu_gradtest("BatchNorm 2", batch_norm, rand(Float32, 5,4), 5)

instancenorm = [InstanceNorm]
gpu_gradtest("InstanceNorm", instancenorm, r, 1)

groupnorm = [GroupNorm]
gpu_gradtest("GroupNorm", groupnorm, rand(Float32, 28,28,3,1), 3, 1)

@testset "function layers" begin
  x = rand(3,3)
  gpu_gradtest(x -> sum(Flux.normalise(x; dims=1)), x)
  gpu_gradtest(x -> sum(Flux.normalise(x; dims=2)), x)
  gpu_gradtest(x -> sum(Flux.normalise(x)), x)
end

@testset "Zeros mapped for $cl" for cl in (Conv, ConvTranspose, CrossCor, DepthwiseConv)
  l = cl((2,2), 1=>3, bias = false) |> gpu
  ip = zeros(Float32, 28,28,1,1) |> gpu
  if l isa BROKEN_LAYERS
    @test_broken sum(l(ip)) ≈ 0.f0
    @test_broken gradient(() -> sum(l(ip)), Flux.params(l)) isa Flux.Zygote.Grads
  else
    @test sum(l(ip)) ≈ 0.f0
    gs = gradient(() -> sum(l(ip)), Flux.params(l))
    @test l.bias ∉ gs.params 
  end
end

@testset "Dense with Zeros bias" begin
  l = Dense(ones(Float32, 4,3), Flux.Zeros()) |> gpu
  ip = zeros(Float32, 3, 7) |> gpu

  @test sum(l(ip)) ≈ 0.f0  
  gs = gradient(() -> sum(l(ip)), Flux.params(l))
  @test l.b ∉ gs.params 
end