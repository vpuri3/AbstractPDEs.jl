#
using PDEInterfaces
let
    # add dependencies to env stack
    pkgpath = dirname(dirname(pathof(PDEInterfaces)))
    tstpath = joinpath(pkgpath, "test")
    !(tstpath in LOAD_PATH) && push!(LOAD_PATH, tstpath)
    nothing
end

using OrdinaryDiffEq, CUDA, LinearAlgebra, ComponentArrays
using Lux, Random, JLD2, SciMLSensitivity, Zygote
using Optimization, OptimizationOptimJL, OptimizationOptimisers, Optimisers
using Plots

CUDA.allowscalar(false)

rng = Random.default_rng()
Random.seed!(rng, 0)

"""
1D Burgers + Closure equation

∂t(vx) = -vx * ∂x(vx) + ν∂xx(vx) + ∂x(η)
∂t(η ) = -u  * ∂x(η ) + ν∂xx(η ) + NN_η_forcing(vx)

u(t=0) = vx0 (from data)
η(t=0) = NN_η_init(vx0)
"""

""" data """
function ut_from_data(filename)
    data = jldopen(filename)
    
    t = data["t"]
    u = data["u_coarse"]

    u, t
end

function optcb(p, l, pred;
               doplot=false,
               space=space,
               steptime=nothing,
               iter=nothing,
               niter=nothing,
              )

    steptime = steptime isa Nothing ? 0.0 : steptime
    iter = iter isa Nothing ? 0 : iter
    niter = niter isa Nothing ? 0 : niter

    println(
            "[$iter/$niter] \t Time $(round(steptime; digits=2))s \t Loss: " *
            "$(round(l; digits=8)) \t "
           )

    return false
end

""" space discr """
function setup_model1(N, ν, filename;
                      p=nothing,
                      model=nothing,
                      odealg=SSPRK43(),
                     )

    model = model isa Nothing ? (u, p, t, space) -> zero(u) : model

    """ space discr """
    space = FourierSpace(N) |> gpu
    discr = Collocation()

    (x,) = points(space)

    """ get data """
    vx_data, t_data = ut_from_data(datafile)
    vx0 = @views vx_data[:,:,1]

    vx_data = gpu(vx_data)
    n_data = length(vx_data)

    """ initial conditions """
    u0 = ComponentArray(;vx=vx0, η=zero(vx0)) |> gpu

    """ operators """
    space = make_transform(space, u0.vx; isinplace=false, p=u0)

    Dx = gradientOp(space, discr)[1]
    Dx = cache_operator(Dx, u0.η)

    Ddt_vx = begin
        A = diffusionOp(ν, space, discr)

        function burgers!(v, u, p, t)
            copyto!(v, p.vx)
        end

        function forcing!(f, u, p, t)
            ηx = Dx * p.η
            copy!(f, ηx)
        end

        C = advectionOp((zero(u0.vx),), space, discr; vel_update_funcs=(burgers!,))
        F = forcingOp(zero(u0.vx), space, discr; f_update_func=forcing!)

        cache_operator(A-C+F, u0.vx)
    end

    Ddt_η = begin
        A = diffusionOp(ν, space, discr)

        function vel!(v, u, p, t)
            copy!(v, p.vx)
        end

        C = advectionOp((zero(u0.η),), space, discr; vel_update_funcs=(vel!,))

        cache_operator(A-C, u0.η)
    end

    """ time discr """
    function dudt(u, p, t)
        Zygote.ignore() do
            SciMLOperators.update_coefficients!(Ddt_vx, u.vx, u, t)
            SciMLOperators.update_coefficients!(Ddt_η , u.η , u, t)
        end

        dvx = Ddt_vx * u.vx
        dη  = Ddt_η  * u.η

        dη += 1f-4 * model.η_forcing(u.vx, p.η_forcing, st.η_forcing)[1]

        ComponentArray(vcat(dvx |> vec, dη |> vec), getaxes(u))
    end

    tspan = (t_data[1], t_data[end])
    prob  = ODEProblem(dudt, u0, tspan, p; reltol=1f-4, abstol=1f-4)
    sense = InterpolatingAdjoint(autojacvec=ZygoteVJP(allow_nothing=true))

    function predict(p; callback=nothing)

        η0 = 1f-4 * model.η_init(u0.vx, p.η_init, st.η_init)[1]

        prob = remake(
                      prob,
                      u0=ComponentArray(vcat(u0.vx |> vec, η0 |> vec), getaxes(u0))
                     )

        sol  = solve(prob,
                     odealg,
                     p=p,
                     sensealg=sense,
                     callback=callback,
                     saveat=t_data,
                    )

        vxs = Tuple(sol.u[i].vx for i=1:length(sol))
        vx = cat(vxs...;dims=3)

        ηs = Tuple(sol.u[i].η for i=1:length(sol))
        η = cat(ηs...;dims=3)

        vx, η
    end

    function loss(p)
        vx, _ = predict(p)
        loss = sum(abs2.(vx .- vx_data))

        loss, vx
    end

    predict, loss, space
end

odecb = begin
    function affect!(int)
        println(int.t)
    end

    DiscreteCallback((u,t,int) -> true, affect!, save_positions=(false,false))
end

##############################################
filename = "burgers_nu1em3_n1024"
datafile = joinpath(@__DIR__, filename, filename * ".jld2")
savefile = joinpath(@__DIR__, filename, "model1" * ".jld2")

N = 128
ν = 1f-3

model, ps, st = begin
    nn_η_init = Lux.Chain(
                          Lux.Dense(N, N, tanh),
                          Lux.Dense(N, N),
                         )

    p_η_init, st_η_init = Lux.setup(rng, nn_η_init)

    nn_η_forcing = Lux.Chain(
                             Lux.Dense(N,N, tanh),
                             Lux.Dense(N,N),
                            )

    p_η_forcing, st_η_forcing = Lux.setup(rng, nn_η_forcing)

    α = rand(Float32)
    β = rand(Float32)

    model = (;
             η_init = nn_η_init,
             η_forcing = nn_η_forcing,
            )

    ps = ComponentArray(;
                        η_init=ComponentArray(p_η_init),
                        η_forcing=ComponentArray(p_η_forcing),
                        #α=α,
                        #β=β,
                       ) |> gpu

    st = (;
          η_init = st_η_init,
          η_forcing = st_η_forcing,
         )

    model, ps, st
end
##############################################

predict, loss, space = setup_model1(N, ν, datafile; p=ps, model=model);

# dummy calls
optf = p -> loss(p)[1]
println("fwd"); @time optf(ps) |> display
#println("bwd"); @time Zygote.gradient(optf, ps) |> display

#Zygote.gradient(optf, ps)
##@time Zygote.gradient(optf, ps)

#ps = train(loss, ps; alg=ADAM(1f-3), maxiters=1000)

#model = jldsave(savefile; ps)
#
