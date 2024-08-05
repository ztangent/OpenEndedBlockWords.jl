using PDDL, SymbolicPlanners
using Gen, GenParticleFilters
using InversePlanning

include("utils.jl")
include("modeling.jl")
include("proposals.jl")

"""
    run_enumerative_sips(
        domain, state, actions,
        [world_config, goal_space, n_particles];
        kwargs...
    )

Run enumerative SIPS for goal inference from a sequence of observed `actions`,
starting from a `state` in a `domain`. If not provided, `world_config` and 
`goal_space` are constructed from `domain` and `state` using `configure_model`.
By default, `n_particles` is set to the size of `goal_space`.

# Keyword Arguments

- `split_idxs = nothing`: Indices at which to split the observations.
- `resample_cond = :none`: Resampling condition for SIPS particle filter.
- `top_k = 5`: Number of top goals to log.
"""
function run_enumerative_sips(
    domain::Domain, state::State, actions,
    world_config = nothing, goal_space = nothing, n_particles = nothing;
    split_idxs = nothing, resample_cond = :none, top_k::Int = 5
)
    # Fill in default argument values
    if isnothing(world_config) || isnothing(goal_space)
        world_config, goal_space = configure_model(
            domain, state; goal_prior_type=:uniform, act_temperature=1.0
        )
    end
    if isnothing(n_particles)
        n_particles = length(goal_space)
    end

    # Convert actions to iterator over timestep-choicemap pairs
    t_obs_iter = act_choicemap_pairs(actions; split_idxs)

    # Construct iterator over goal choicemaps for enumerative initialization
    goal_addr = :init => :agent => :goal => :goal
    goal_strata = choiceproduct((goal_addr, goal_space))
    
    # Define logging callback
    callback = construct_logger(goal_addr, goal_space, top_k)

    # Configure SIPS particle filter
    sips = SIPS(world_config; resample_cond)

    # Run particle filter
    pf_state = sips(
        n_particles, t_obs_iter;
        init_args=(init_strata=goal_strata,),
        callback=callback
    );

    # Extract data from callbacks
    data = merge(callback.logger.data, callback.verbose.data)

    return (pf_state, data)
end

"""
    run_open_ended_sips(
        domain, state, actions,
        [world_config, goal_space, n_init_particles = 10, n_add_particles = 10];
        kwargs...
    )

Run open-ended SIPS for goal inference from a sequence of observed `actions`,
starting from a `state` in a `domain`. If not provided, `world_config` and
`goal_space` are constructed from `domain` and `state` using `configure_model`.

# Keyword Arguments

- `goal_proposal`: Goal proposal to use.
- `split_idxs = nothing`: Indices at which to split the observations.
- `top_k = 5`: Number of top goals to log.
"""
function run_open_ended_sips(
    domain::Domain, state::State, actions,
    world_config = nothing, goal_space = nothing,
    n_init_particles = 10, n_add_particles = 10;
    ngram_dist = construct_ngram_dist(domain, state),
    goal_proposal = chained_tower_proposal,
    rejuvenation = :always, rejuv_thresh = 1.0, rejuv_prob = 0.5,
    split_idxs = nothing, top_k::Int = 5
)
    # Fill in default argument values
    if isnothing(world_config) || isnothing(goal_space)
        world_config, goal_space = configure_model(
            domain, state; goal_prior_type=:uniform, act_temperature=1.0
        )
    end

    # Convert actions to iterator over timestep-choicemap pairs
    t_obs_iter = act_choicemap_pairs(actions; split_idxs)
    # Accumulate observation choicemaps
    t_accum_iter = accum_observations(t_obs_iter)
    # Simulate trajectory to get all expected states
    trajectory = PDDL.simulate(domain, state, actions)
    
    # Define logging callback
    goal_addr = :init => :agent => :goal => :goal
    callback = construct_logger(goal_addr, goal_space, top_k)

    # Configure SIPS particle filter
    sips = SIPS(world_config)

    # Initialize particle filter at timestep 0
    pf_state = sips_init(
        sips, n_init_particles;
        init_timestep=0,
        init_proposal=goal_proposal,
        init_proposal_args=(
            domain, trajectory[first(split_idxs)+1],
            actions[1:first(split_idxs)],
            ngram_dist, goal_addr
        ),
        callback
    )

    # Run open-ended goal inference by resizing the particle filter
    for (i, (t, obs)) in enumerate(t_obs_iter)
        accum_obs = last(t_accum_iter[i])
        cur_state = trajectory[t+1]
        # Get current log marginal likelihood estimate
        lml_est = get_lml_est(pf_state)
        # Update existing particles with new observations
        pf_state = pf_update!(pf_state, (t, world_config),
                              (UnknownChange(), NoChange()), obs)
        if i == 1 # Do not add more particles at first observation
            callback(t, obs, pf_state)
            continue
        end
        # Decide whether to rejuvenate by introducing new particles
        if rejuvenation == :adaptive
            # Resample if newly observed action is less likely than random
            new_lml_est = get_lml_est(pf_state)
            n_available = length(collect(available(domain, trajectory[t])))
            rejuvenate = new_lml_est - lml_est < log(rejuv_thresh/n_available)
        elseif rejuvenation == :randadapt
            # Stochastic version of adaptive rejuvenation
            new_lml_est = get_lml_est(pf_state)
            n_available = length(collect(available(domain, trajectory[t])))
            log_odds = log(rejuv_thresh/n_available) - (new_lml_est - lml_est)
            p_rejuvenate = exp(log_odds) / (1 + exp(log_odds)) 
            rejuvenate = rand() < p_rejuvenate
        elseif rejuvenation == :random
            # Rejuvenate at random
            rejuvenate = rand() < rejuv_prob
        elseif rejuvenation == :always
            rejuvenate = true
        end
        if rejuvenate
            # Introduce new particles by sampling from proposal
            pf_state = pf_introduce!(
                pf_state, accum_obs, goal_proposal,
                (domain, cur_state, actions[1:t], ngram_dist, goal_addr),
                n_add_particles
            )
            # Keep likely particles via residual resampling
            pf_state = pf_residual_resize!(pf_state, n_init_particles)
            # Coalesce choicemap equivalent particles
            pf_state = pf_coalesce!(pf_state, by=Gen.get_choices)
        end
        callback(t, obs, pf_state)
    end

    # Extract data from callbacks
    data = merge(callback.logger.data, callback.verbose.data)

    return (pf_state, data)
end

"""
    run_proposal_only(
        domain, state, actions,
        [world_config, goal_space, n_particles = 10];
        kwargs...
    )

Run proposal-only goal inference from a sequence of observed `actions`,
starting from a `state` in a `domain`. If not provided, `world_config` and
`goal_space` are constructed from `domain` and `state` using `configure_model`.

# Keyword Arguments

- `goal_proposal`: Goal proposal to use.
- `split_idxs = nothing`: Indices at which to split the observations.
- `resample_cond = :ess`: Resampling condition for SIPS particle filter.
- `top_k = 5`: Number of top goals to log.
"""
function run_proposal_only(
    domain::Domain, state::State, actions,
    world_config = nothing, goal_space = nothing, n_particles = 10;
    ngram_dist = construct_ngram_dist(domain, state),
    goal_proposal = chained_tower_proposal,
    split_idxs = nothing, top_k::Int = 5
)
    # Fill in default argument values
    if isnothing(world_config) || isnothing(goal_space)
        world_config, goal_space = configure_model(
            domain, state; goal_prior_type=:uniform, act_temperature=1.0
        )
    end

    # Convert actions to iterator over timestep-choicemap pairs
    t_obs_iter = act_choicemap_pairs(actions; split_idxs)
    pushfirst!(t_obs_iter, (0 => choicemap()))
    # Simulate trajectory to get all expected states
    trajectory = PDDL.simulate(domain, state, actions)
    
    # Define logging callback
    goal_addr = :init => :agent => :goal => :goal
    callback = construct_logger(goal_addr, goal_space, top_k)

    # Configure SIPS particle filter
    sips = SIPS(world_config, resample_cond=:none)

    # Repeatedly initialize particle filter with new proposal
    pf_state = nothing
    for (t, obs) in t_obs_iter
        cur_state = trajectory[t+1]
        pf_state = sips_init(
            sips, n_particles;
            init_timestep=0,
            init_proposal=goal_proposal,
            init_proposal_args=(domain, cur_state, actions[1:t],
                                ngram_dist, goal_addr)
        )
        pf_state.log_weights .= 0
        pf_coalesce!(pf_state)
        callback(t, obs, pf_state)
    end

    # Extract data from callbacks
    data = merge(callback.logger.data, callback.verbose.data)

    return (pf_state, data)
end

"Construct data logger callbacks."
function construct_logger(goal_addr, goal_space, top_k::Int = 5)
    logger_cb = DataLoggerCallback(
        t = (t, pf) -> t::Int,
        time = (t, pf) -> time(),
        goal_probs = (t, pf) -> begin 
            ps = probvec(pf, goal_addr, goal_space)::Vector{Float64}
            return any(isnan.(ps)) ? zero(ps) : ps
        end,
        lml_est = pf -> string(log_ml_estimate(pf))::String,
    )
    verbose_cb = DataLoggerCallback(
        verbose = true,
        t = (t, pf) -> t::Int,
        act = (t, obs, pf) -> begin
            if t == 0
                write_pddl(PDDL.no_op)::String
            else
                write_pddl(obs[:timestep => t => :act => :act])::String
            end
        end,
        ess = (t, pf) -> begin
            s = get_ess(pf)::Float64
            return isnan(s) ? Float64(length(pf.traces)) : s
        end,
        top_k_goals = (t, pf) -> begin
            pmap = proportionmap(pf, goal_addr)
            sorted_goals = sort!(collect(pmap), by=last, rev=true)
            n_goals = length(sorted_goals)
            sorted_goals = first.(sorted_goals[1:min(top_k, n_goals)])
            return sorted_goals::Vector{String}
        end,
        top_k_probs = (t, pf) -> begin
            pmap = proportionmap(pf, goal_addr)
            sorted_probs = sort!(collect(pmap), by=last, rev=true)
            n_goals = length(sorted_probs)
            sorted_probs = last.(sorted_probs[1:min(top_k, n_goals)])
            sorted_probs = replace!(sorted_probs, NaN => 0.0)
            return sorted_probs::Vector{Float64}
        end
    )
    callback = CombinedCallback(logger=logger_cb, verbose=verbose_cb)
    return callback
end

"Given an iterator over timestep-choicemap pairs, accumulate the observations."
function accum_observations(t_obs_iter::Vector)
    timesteps = first.(t_obs_iter)
    observations = last.(t_obs_iter)
    t_obs_iter = map(eachindex(timesteps)) do i
        t = timesteps[i]
        cmap = reduce(merge, observations[1:i])
        return t => cmap
    end
    return t_obs_iter
end
accum_observations(t_obs_iter) = accum_observations(collect(t_obs_iter))
