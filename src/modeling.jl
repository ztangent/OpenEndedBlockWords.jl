using PDDL, SymbolicPlanners
using Gen, GenParticleFilters
using InversePlanning

include("utils.jl")
include("ngrams.jl")
include("heuristics.jl")

WORDS = load_word_list(joinpath(@__DIR__, "../assets", "words.txt"))
WORD_FREQS = load_wordfreq_list(joinpath(@__DIR__, "../assets", "wordfreqs.txt"))

"""
    configure_model(domain, state; kwargs...)

Configure a model for open-ended goal inference via inverse planning in the
Block Words domain, using either a uniform prior over all possible words
that can be spelled out of the blocks in the initial state, or a prior
based on n-gram statistics.

# Keyword Arguments

- `goal_prior_type`: Type of goal prior to use. One of `:uniform` or `:ngram`.
- `goal_prior_kwargs`: Keyword arguments to pass to goal prior constructor.
- `n_iters`: Number of iterations to run RTHS planner for at each timestep.
- `search_method`: Search method to use for RTHS planner (`:bfs` or `:astar`).
- `max_nodes`: Maximum number of nodes to expand during planning.
- `act_temperature`: Temperature for action selection.
- `replan_period`: Number of timesteps between replanning.
- `replan_cond`: (Non-periodic) condition for re-planning at each timestep.
"""
function configure_model(
    domain::Domain, state::State;
    goal_prior_type = :uniform, goal_prior_kwargs = (),
    n_iters::Int = 1, max_nodes::Int = 50, act_temperature::Real = 1.0,
    replan_period::Int = 1, replan_cond::Symbol = :unplanned,
    plan_at_init::Bool = true, search_method = :bfs
)
    # Construct goal prior
    goal_prior, goal_space, word_dist =
        construct_goal_prior(domain, state, goal_prior_type;
                             goal_prior_kwargs...)

    # Configure agent model with domain, planner, and goal prior
    heuristic = FFHeuristic()
    heuristic = memoized(precomputed(heuristic, domain, state))
    planner = RealTimeHeuristicSearch(
        heuristic; n_iters, max_nodes, update_method = :dijkstra,
        reuse_search = true, reuse_paths = (search_method == :astar),
        search_neighbors = (search_method == :bfs) ? :none : :all,
        h_mult = (search_method == :bfs) ? 0.0 : 1.0
    )
    agent_config = AgentConfig(
        domain, planner;
        # Assume fixed goal over time
        goal_config = StaticGoalConfig(goal_prior),
        # Assume the agent refines policy at every step
        replan_args = (
            plan_at_init = plan_at_init, # Flag to plan at initial timestep
            rand_budget = false, # Fixed search budget
            prob_replan = 0.0, # Probability of replanning at each timestep
            prob_refine = 1.0, # Probability of refining policy at each timestep
            replan_period = replan_period, # Refine solution at fixed schedule
            replan_cond = replan_cond, # Refine solution if condition is met
        ),
        # Assume action noise
        act_temperature = act_temperature
    )

    # Configure world model with planner, goal prior, initial state
    world_config = WorldConfig(
        agent_config = agent_config,
        env_config = PDDLEnvConfig(domain, state)
    )

    return (world_config, goal_space, heuristic)
end

"""
    construct_goal_prior(domain, state, type; kwargs...)

Construct a goal prior for open-ended goal inference in the Block Words domain.
"""
function construct_goal_prior(
    domain::Domain, state::State, type = :uniform;
    kwargs...
)
    if type == :uniform
        return construct_uniform_goal_prior(domain, state; kwargs...)
    elseif type == :categorical
        return construct_categorical_goal_prior(domain, state; kwargs...)
    elseif type == :ngram
        return construct_ngram_goal_prior(domain, state; kwargs...)
    else
        error("Invalid goal prior type: $type")
    end
end

"""
    construct_uniform_goal_prior(domain, state; kwargs...)

Construct a uniform goal prior in the Block Words domain. Returns a goal prior
generative function and a list of possible goal words.

# Keyword Arguments

- `vocab`: A set or dictionary with words as keys.
"""
function construct_uniform_goal_prior(
    domain::Domain, state::State;
    vocab = WORDS, min_chars::Int=3, max_chars::Int=8,
    kwargs...
)
    chars = [string(obj) for obj in PDDL.get_objects(domain, state, :block)]
    chars = join(chars)
    vocab = filter_vocab(vocab, chars)
    words = sort!(collect(keys(vocab)))
    filter!(w -> min_chars <= length(w) <= max_chars, words)
    word_dist = UniformWordDist(words)
    @gen function uniform_goal_prior()
        goal ~ word_dist()
        return Specification(word_to_terms(goal))
    end
    return (uniform_goal_prior, words, word_dist)
end

"""
    construct_categorical_goal_prior(domain, state; kwargs...)

Construct a categorical goal prior in the Block Words domain.
Returns a goal prior generative function and a list of possible goal words.

# Keyword Arguments

- `vocab`: A set or dictionary with words as keys.
"""
function construct_categorical_goal_prior(
    domain::Domain, state::State;
    vocab = WORDS, min_chars::Int=3, max_chars::Int=8,
    multiplier = 1000, temperature = nothing,
    kwargs...
)
    chars = [string(obj) for obj in PDDL.get_objects(domain, state, :block)]
    chars = join(chars)
    vocab = filter_vocab(vocab, chars)
    for word in keys(vocab)
        min_chars <= length(word) <= max_chars && continue
        delete!(vocab, word)
    end
    words = sort!(collect(keys(vocab)))
    word_dist = CategoricalWordDist(vocab; multiplier, temperature)
    @gen function categorical_goal_prior()
        goal ~ word_dist()
        return Specification(word_to_terms(goal))
    end
    return (categorical_goal_prior, words, word_dist)
end

"""
    construct_ngram_goal_prior(domain, state; kwargs...)

Construct a goal prior based on n-gram statistics in the Block Words domain.
Returns a goal prior generative function and a list of possible goal words.

# Keyword Arguments
- `vocab`: A set or dictionary with words as keys.
- `n`: The window size for the `n`-gram.
- `reversed`: Whether to use reversed n-grams.
- `min_chars`: Minimum length of goal words.
- `max_chars`: Maximum length of goal words.
- `multiplier`: Multiplier for n-gram counts.
- `temperature`: Temperature for n-gram sampling.
"""
function construct_ngram_goal_prior(
    domain::Domain, state::State;
    vocab = WORDS, n::Int = 5, reversed::Bool = true,
    min_chars::Int=3, max_chars::Int=8,
    multiplier = 1000, temperature = nothing,
    kwargs...
)
    chars = [string(obj) for obj in PDDL.get_objects(domain, state, :block)]
    chars = join(chars)
    vocab = filter_vocab(vocab, chars)
    for word in keys(vocab)
        min_chars <= length(word) <= max_chars && continue
        delete!(vocab, word)
    end
    ngram_dist = ConstrainedNgramWordDist(
        vocab, n, chars;
        reversed, temperature, multiplier, kwargs...
    )
    @gen function ngram_goal_prior()
        goal ~ ngram_dist("")
        spec = Specification(word_to_terms(goal))
        return spec
    end
    words = sort!(collect(keys(vocab)))
    return (ngram_goal_prior, words, ngram_dist)
end

"""
    construct_ngram_dist(domain, state; kwargs...)

Construct a character-level n-gram model over words in a Block Words `state`.

# Keyword Arguments
- `vocab`: A set or dictionary with words as keys.
- `n`: The window size for the `n`-gram.
- `reversed`: Whether to use reversed n-grams.
- `min_chars`: Minimum word length.
- `max_chars`: Maximum word length.
- `multiplier`: Multiplier for n-gram counts.
- `temperature`: Temperature for n-gram sampling.
"""
function construct_ngram_dist(
    domain::Domain, state::State;
    vocab = WORDS, n::Int = 5, reversed::Bool = true,
    min_chars::Int=3, max_chars::Int=8,
    multiplier = 1000, temperature = nothing,
    kwargs...
)
    chars = [string(obj) for obj in PDDL.get_objects(domain, state, :block)]
    chars = join(chars)
    vocab = filter_vocab(vocab, chars)
    for word in keys(vocab)
        min_chars <= length(word) <= max_chars && continue
        delete!(vocab, word)
    end
    ngram_dist = ConstrainedNgramWordDist(
        vocab, n, chars;
        reversed, temperature, multiplier, kwargs...
    )
    return ngram_dist
end
