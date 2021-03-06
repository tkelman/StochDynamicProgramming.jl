################################################################################
# Test SDDP functions
################################################################################
using FactCheck, StochDynamicProgramming, JuMP, Clp

# Test SDDP with a one dimensional stock:
facts("SDDP algorithm: 1D case") do
    solver = ClpSolver()

    # SDDP's tolerance:
    epsilon = .05
    # maximum number of iterations:
    max_iterations = 2
    # number of scenarios in forward and backward pass:
    n_scenarios = 10
    # number of aleas:
    n_aleas = 5
    # number of stages:
    n_stages = 3

    # define dynamic:
    function dynamic(t, x, u, w)
        return [x[1] - u[1] - u[2] + w[1]]
    end
    # define cost:
    function cost(t, x, u, w)
        return -u[1]
    end

    # Generate probability laws:
    laws = Vector{NoiseLaw}(n_stages)
    proba = 1/n_aleas*ones(n_aleas)
    for t=1:n_stages
        laws[t] = NoiseLaw([0, 1, 3, 4, 6], proba)
    end

    # set initial position:
    x0 = [10.]
    # set bounds on state:
    x_bounds = [(0., 100.)]
    # set bounds on control:
    u_bounds = [(0., 7.), (0., Inf)]

    # Instantiate parameters of SDDP:
    params = StochDynamicProgramming.SDDPparameters(solver, n_scenarios,
                                                    epsilon, max_iterations)

    V = nothing
    model = StochDynamicProgramming.LinearDynamicLinearCostSPmodel(n_stages, u_bounds,
                                                                   x0, cost, dynamic, laws)

    set_state_bounds(model, x_bounds)
    # Test error if bounds are not well specified:
    @fact_throws set_state_bounds(model, [(0,1), (0,1)])

    # Generate scenarios for forward simulations:
    noise_scenarios = simulate_scenarios(model.noises,params.forwardPassNumber)

    sddp_costs = 0

    context("Unsolvable extensive formulation") do
        model_ef = StochDynamicProgramming.LinearDynamicLinearCostSPmodel(n_stages, u_bounds,
                                                                   x0, cost, dynamic, laws)
        x_bounds_ef = [(-2., -1.)]
        set_state_bounds(model_ef, x_bounds_ef)
        @fact_throws extensive_formulation(model_ef, params)
    end

    context("Linear cost") do
        # Compute bellman functions with SDDP:
        V, pbs = solve_SDDP(model, params, 0)
        @fact typeof(V) --> Vector{StochDynamicProgramming.PolyhedralFunction}
        @fact typeof(pbs) --> Vector{JuMP.Model}
        @fact length(pbs) --> n_stages - 1
        @fact length(V) --> n_stages

        # Test if the first subgradient has the same dimension as state:
        @fact size(V[1].lambdas, 2) --> model.dimStates
        @fact V[1].numCuts --> n_scenarios*max_iterations + n_scenarios
        @fact size(V[1].lambdas, 1) --> n_scenarios*max_iterations + n_scenarios

        # Test upper bounds estimation with Monte-Carlo:
        n_simulations = 100
        upb = StochDynamicProgramming.estimate_upper_bound(model, params, V, pbs,
        n_simulations)[1]
        @fact typeof(upb) --> Float64

        sddp_costs, stocks = forward_simulations(model, params, pbs, noise_scenarios)
        # Test error if scenarios are not given in the right shape:
        @fact_throws forward_simulations(model, params, pbs, [1.])

        # Compare sddp cost with those given by extensive formulation:
        ef_cost = StochDynamicProgramming.extensive_formulation(model,params)[1]
        @fact typeof(ef_cost) --> Float64

        # As SDDP result is suboptimal, cost must be greater than those of extensive formulation:
        @fact mean(sddp_costs) > ef_cost --> true

        # Test computation of optimal control:
        aleas = StochDynamicProgramming.extract_vector_from_3Dmatrix(noise_scenarios, 1, 1)
        opt = StochDynamicProgramming.get_control(model, params, pbs, 1, model.initialState, aleas)
        @fact typeof(opt) --> Vector{Float64}

        # Test display:
        StochDynamicProgramming.set_max_iterations(params, 1)
        V, pbs = solve_SDDP(model, params, V, 1)
    end

    context("Value functions calculation") do
        V0 = StochDynamicProgramming.get_lower_bound(model, params, V)
    end

    context("Hotstart") do
        # Test hot start with previously computed value functions:
        V, pbs = solve_SDDP(model, params, V, 0)
        # Test if costs are roughly the same:
        sddp_costs2, stocks = forward_simulations(model, params, pbs, noise_scenarios)
        @fact mean(sddp_costs) --> roughly(mean(sddp_costs2))
    end

    context("Cuts pruning") do
        v = V[1]
        vt = PolyhedralFunction([v.betas[1]; v.betas[1] - 1.], v.lambdas[[1,1],:],  2)
        StochDynamicProgramming.prune_cuts!(model, params, V)
        isactive1 = StochDynamicProgramming.is_cut_relevant(model, 1, vt, params.solver)
        isactive2 = StochDynamicProgramming.is_cut_relevant(model, 2, vt, params.solver)
        @fact isactive1 --> true
        @fact isactive2 --> false
    end

    # Test definition of final cost with a JuMP.Model:
    context("Final cost") do
        function fcost(model, m)
            alpha = getvariable(m, :alpha)
            @constraint(m, alpha == 0.)
        end
        # Store final cost in model:
        model.finalCost = fcost
        V, pbs = solve_SDDP(model, params, 0)
        V, pbs = solve_SDDP(model, params, V, 0)
    end

    context("Piecewise linear cost") do
        # Test Piecewise linear costs:
        model = StochDynamicProgramming.PiecewiseLinearCostSPmodel(n_stages,
        u_bounds, x0,
        [cost],
        dynamic, laws)
        set_state_bounds(model, x_bounds)
        V, pbs = solve_SDDP(model, params, 0)
    end

    context("Stopping criterion") do
        # Compute upper bound every %% iterations:
        params.compute_upper_bound = 1
        params.compute_cuts_pruning = 1
        params.maxItNumber = 30
        V, pbs = solve_SDDP(model, params, V, 0)
        V0 = StochDynamicProgramming.get_lower_bound(model, params, V)
        n_simulations = 1000
        upb = StochDynamicProgramming.estimate_upper_bound(model, params, V, pbs,
                                                            n_simulations)[1]
        @fact abs((V0 - upb)/V0) < params.gap --> true
    end

    context("Dump") do
        # Dump V in text file:
        StochDynamicProgramming.dump_polyhedral_functions("dump.dat", V)
        # Get stored values:
        Vdump = StochDynamicProgramming.read_polyhedral_functions("dump.dat")

        @fact V[1].numCuts --> Vdump[1].numCuts
        @fact V[1].betas --> Vdump[1].betas
        @fact V[1].lambdas --> Vdump[1].lambdas
    end

    context("Compare parameters") do
        paramSDDP = [params for i in 1:3]
        scenarios = StochDynamicProgramming.simulate_scenarios(laws, 1000)
        benchmark_parameters(model, paramSDDP, scenarios, 12)
    end
end


# Test SDDP with a two-dimensional stock:
facts("SDDP algorithm: 2D case") do
    solver = ClpSolver()

    # SDDP's tolerance:
    epsilon = .05
    # maximum number of iterations:
    max_iterations = 2
    # number of scenarios in forward and backward pass:
    n_scenarios = 10
    # number of aleas:
    n_aleas = 5
    # number of stages:
    n_stages = 2

    # define dynamic:
    function dynamic(t, x, u, w)
        return [x[1] - u[1] - u[2] + w[1], x[2] - u[4] - u[3] + u[1] + u[2]]
    end
    # define cost:
    function cost(t, x, u, w)
        return -u[1] - u[3]
    end

    # Generate probability laws:
    laws = Vector{NoiseLaw}(n_stages)
    proba = 1/n_aleas*ones(n_aleas)
    for t=1:n_stages
        laws[t] = NoiseLaw([0, 1, 3, 4, 6], proba)
    end

    # set initial position:
    x0 = [10., 10]
    # set bounds on state:
    x_bounds = [(0., 100.), (0, 100)]
    # set bounds on control:
    u_bounds = [(0., 7.), (0., Inf), (0., 7.), (0., Inf)]

    # Instantiate parameters of SDDP:
    params = StochDynamicProgramming.SDDPparameters(solver, n_scenarios,
                                                    epsilon, max_iterations)
    V = nothing
    context("Linear cost") do
        # Instantiate a SDDP linear model:
        model = StochDynamicProgramming.LinearDynamicLinearCostSPmodel(n_stages,
        u_bounds, x0,
        cost,
        dynamic, laws)
        set_state_bounds(model, x_bounds)


        # Compute bellman functions with SDDP:
        V, pbs = solve_SDDP(model, params, 0)
        @fact typeof(V) --> Vector{StochDynamicProgramming.PolyhedralFunction}
        @fact typeof(pbs) --> Vector{JuMP.Model}

        # Test if the first subgradient has the same dimension as state:
        @fact length(V[1].lambdas[1, :]) --> model.dimStates

        # Test upper bounds estimation with Monte-Carlo:
        n_simulations = 100
        upb = StochDynamicProgramming.estimate_upper_bound(model, params, V, pbs,
        n_simulations)[1]
        @fact typeof(upb) --> Float64


        # Test a simulation upon given scenarios:
        noise_scenarios = simulate_scenarios(model.noises,n_simulations)

        sddp_costs, stocks = forward_simulations(model, params, pbs, noise_scenarios)

        # Compare sddp cost with those given by extensive formulation:
        ef_cost = StochDynamicProgramming.extensive_formulation(model,params)[1]
        @fact typeof(ef_cost) --> Float64

        @fact mean(sddp_costs) --> roughly(ef_cost)

    end


    context("Dump") do
        # Dump V in text file:
        StochDynamicProgramming.dump_polyhedral_functions("dump.dat", V)
        # Get stored values:
        Vdump = StochDynamicProgramming.read_polyhedral_functions("dump.dat")

        @fact V[1].numCuts --> Vdump[1].numCuts
        @fact V[1].betas --> Vdump[1].betas
        @fact V[1].lambdas --> Vdump[1].lambdas
    end
end

