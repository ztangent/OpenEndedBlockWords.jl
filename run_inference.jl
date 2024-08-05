using PDDL, SymbolicPlanners
using Gen, GenParticleFilters
using InversePlanning
using JSON3

using DataStructures: OrderedDict

include("src/plan_io.jl")
include("src/utils.jl")
include("src/inference.jl")

"Helper function that iterates over Cartesian product of named arguments."
function namedproduct(args::NamedTuple{Ks}) where {Ks}
    args = map(x -> applicable(iterate, x) ? x : (x,), args)
    iter = (NamedTuple{Ks}(x) for x in Iterators.product(args...))
    return iter
end

# Define directory paths
PROBLEM_DIR = joinpath(@__DIR__, "dataset", "problems")
PLAN_DIR = joinpath(@__DIR__, "dataset", "plans")
STIMULI_DIR = joinpath(@__DIR__, "dataset", "stimuli")
RESULTS_DIR = joinpath(@__DIR__, "results")
mkpath(RESULTS_DIR)

# Load domain
DOMAIN = load_domain(joinpath(@__DIR__, "dataset", "domain.pddl"))
COMPILED_DOMAINS = Dict{String, Domain}()

# Load problems
PROBLEMS = OrderedDict{String, Problem}()
paths = readdir(PROBLEM_DIR, join=true)
filter!(p -> endswith(p, ".pddl") && startswith(basename(p), "problem"), paths)
for path in paths
    p_id = replace(splitext(basename(path))[1], "problem-" => "")
    problem = load_problem(path)
    PROBLEMS[p_id] = problem
end

# Load plans and judgment points
PLAN_IDS, PLANS, _, SPLITPOINTS = load_plan_dataset(PLAN_DIR, r"plan-(.+)")

## Define parameters ##

PARAMS = (
    METHOD = [:open_ended,], # :enumerative, :open_ended, :proposal_only
    # Planner and policy parameters
    ACT_TEMPERATURE = [1.0,],
    SEARCH_METHOD = [:astar,], # :astar, :bfs
    MAX_NODES = [100], # [0, 5, 10, 20, 50, 100, 200, 500],
    REPLAN_PERIOD = [1],
    # Goal prior parameters
    GOAL_PRIOR_TYPE = [:categorical,], # :uniform, :ngram, :categorical
    MIN_CHARS = 3,
    MAX_CHARS = 8, 
    # N-gram parameters
    NGRAM_VOCAB = [:weighted], # :uniform, :weighted 
    NGRAM_SIZE = [5,],
    NGRAM_MULTIPLIER = [100,],
    NGRAM_TEMPERATURE = [16.0], # [1.0, 2.0, 4.0, 8.0, 16.0],
    NGRAM_EPSILON = [0.0], # [0.05, 0.10, 0.15, 0.20, 0.25],
    # Proposal parameters
    PROPOSAL_TYPE = [:chained,], # :any_tower, :last_tower, :next_tower, :chained
    # Number of particles
    N_INIT_PARTICLES = [10], # [2, 5, 10, 20, 50,],
    N_ADD_PARTICLES = [nothing,],
    # Number of trials
    N_TRIALS = [(k -> 100 ÷ k)], # 10,
    MIN_TRIALS = 10,
)

## Run main experiment loop ##

for params in namedproduct(PARAMS)
    println("==== PARAMS ====")
    println()
    for (k, v) in pairs(params)
        println("$k = $v")
    end
    N_ADD_PARTICLES = isnothing(params.N_ADD_PARTICLES) ?
        params.N_INIT_PARTICLES : params.N_ADD_PARTICLES 
    println()
    for plan_id in PLAN_IDS
        println("=== Plan: $plan_id ===")
        println()
        
        # Load problem, plan, and splitpoints
        problem = PROBLEMS[plan_id]
        plan = PLANS[plan_id]
        splitpoints = SPLITPOINTS[plan_id]

        # Extract true goal from problem
        goal_word = terms_to_word(problem.goal)

        # Compile domain for problem
        domain = get!(COMPILED_DOMAINS, plan_id) do
            println("Compiling domain for problem $plan_id...")
            println()
            state = initstate(DOMAIN, problem)
            domain, _ = PDDL.compiled(DOMAIN, state)
            return domain
        end

        # Initialize state
        state = initstate(domain, problem)

        # Select vocabulary
        vocab = params.NGRAM_VOCAB == :uniform ? WORDS : WORD_FREQS

        # Configure model with uniform goal prior
        world_config, goal_space, heuristic = configure_model(
            domain, state;
            act_temperature = params.ACT_TEMPERATURE,
            search_method = params.SEARCH_METHOD,
            max_nodes = params.MAX_NODES,
            plan_at_init = params.METHOD != :proposal_only,
            replan_period = params.REPLAN_PERIOD,
            goal_prior_type = params.GOAL_PRIOR_TYPE,
            goal_prior_kwargs = (
                vocab = vocab,
                n = params.NGRAM_SIZE,
                min_chars = params.MIN_CHARS,
                max_chars = params.MAX_CHARS,
                multiplier = params.NGRAM_MULTIPLIER,
                temperature = params.NGRAM_TEMPERATURE,
                epsilon = params.NGRAM_EPSILON
            )
        )

        # Set up ngram distribution for proposals
        ngram_dist = construct_ngram_dist(
            domain, state;
            vocab = vocab,
            n = params.NGRAM_SIZE,
            min_chars = params.MIN_CHARS,
            max_chars = params.MAX_CHARS,
            multiplier = params.NGRAM_MULTIPLIER,
            temperature = params.NGRAM_TEMPERATURE,
            epsilon = params.NGRAM_EPSILON
        )

        # Select proposal
        goal_proposal = if params.PROPOSAL_TYPE == :any_tower
            any_tower_proposal
        elseif params.PROPOSAL_TYPE == :last_tower
            last_tower_proposal
        elseif params.PROPOSAL_TYPE == :next_tower
            next_tower_proposal
        elseif params.PROPOSAL_TYPE == :chained
            chained_tower_proposal
        else
            error("Unknown proposal type: $PROPOSAL_TYPE")
        end

        # Iterate over trials
        n_trials = (params.METHOD == :enumerative) ? 1 : params.N_TRIALS
        if n_trials isa Function
            n_trials = max(n_trials(N_ADD_PARTICLES), params.MIN_TRIALS)
            println("Running $n_trials trials...\n")
        end
        for trial_id in 1:n_trials
            if n_trials > 1
                println("=== Trial: $trial_id ===")
                println()
            end

            # Run inference
            t_start = time()
            if params.METHOD == :enumerative
                # Run enumerative SIPS
                pf_state, data = run_enumerative_sips(
                    domain, state, plan,
                    world_config, goal_space,
                    split_idxs = splitpoints
                )
                config = OrderedDict(
                    :method => :enumerative,
                    :act_temperature => params.ACT_TEMPERATURE,
                    :search_method => params.SEARCH_METHOD,
                    :max_nodes => params.MAX_NODES,
                    :replan_period => params.REPLAN_PERIOD,
                    :goal_prior_type => params.GOAL_PRIOR_TYPE,
                    :min_chars => params.MIN_CHARS,
                    :max_chars => params.MAX_CHARS,
                )
                if params.GOAL_PRIOR_TYPE in (:ngram, :categorical)
                    config[:ngram_vocab] = params.NGRAM_VOCAB
                    config[:ngram_size] = params.NGRAM_SIZE
                    config[:ngram_multiplier] = params.NGRAM_MULTIPLIER
                    config[:ngram_temperature] = params.NGRAM_TEMPERATURE
                    config[:ngram_epsilon] = params.NGRAM_EPSILON
                end
            elseif params.METHOD == :open_ended
                # Run open-ended SIPS
                pf_state, data = run_open_ended_sips(
                    domain, state, plan,
                    world_config, goal_space,
                    params.N_INIT_PARTICLES,
                    N_ADD_PARTICLES;
                    goal_proposal = goal_proposal,
                    ngram_dist = ngram_dist,
                    split_idxs = splitpoints
                )
                config = OrderedDict(
                    :method => :open_ended,
                    :goal_prior_type => params.GOAL_PRIOR_TYPE,
                    :act_temperature => params.ACT_TEMPERATURE,
                    :search_method => params.SEARCH_METHOD,
                    :max_nodes => params.MAX_NODES,
                    :replan_period => params.REPLAN_PERIOD,
                    :min_chars => params.MIN_CHARS,
                    :max_chars => params.MAX_CHARS,
                    :proposal_type => params.PROPOSAL_TYPE,
                    :n_init_particles => params.N_INIT_PARTICLES,
                    :n_add_particles => N_ADD_PARTICLES,
                    :ngram_vocab => params.NGRAM_VOCAB,
                    :ngram_size => params.NGRAM_SIZE,
                    :ngram_multiplier => params.NGRAM_MULTIPLIER,
                    :ngram_temperature => params.NGRAM_TEMPERATURE,
                    :ngram_epsilon => params.NGRAM_EPSILON
                )
            elseif params.METHOD == :proposal_only
                # Run proposal-only inference
                pf_state, data = run_proposal_only(
                    domain, state, plan,
                    world_config, goal_space, N_ADD_PARTICLES;
                    goal_proposal = goal_proposal,
                    ngram_dist = ngram_dist,
                    split_idxs = splitpoints
                )
                config = OrderedDict(
                    :method => :proposal_only,
                    :min_chars => params.MIN_CHARS,
                    :max_chars => params.MAX_CHARS,
                    :proposal_type => params.PROPOSAL_TYPE,
                    :n_particles => N_ADD_PARTICLES,
                    :ngram_vocab => params.NGRAM_VOCAB,
                    :ngram_size => params.NGRAM_SIZE,
                    :ngram_multiplier => params.NGRAM_MULTIPLIER,
                    :ngram_temperature => params.NGRAM_TEMPERATURE,
                    :ngram_epsilon => params.NGRAM_EPSILON
                )
            else
                error("Unknown inference method: $METHOD")
            end

            # Empty heuristic cache
            heuristic isa MemoizedHeuristic && empty!(heuristic)

            # Add configuration and goal space to results
            data[:t_start] = t_start
            data[:config] = config
            data[:goal_space] = goal_space
            data = sort(data, by = x -> (length(string(x)), x))

            # Save results to JSON file
            subdir = joinpath(RESULTS_DIR, string(params.METHOD))
            mkpath(subdir)
            filename = "results-$(params.METHOD)-$plan_id"
            if params.METHOD == :enumerative
                filename *= "-prior=$(params.GOAL_PRIOR_TYPE)"
                if params.GOAL_PRIOR_TYPE == :ngram
                    filename *= "-ngram=$(params.NGRAM_VOCAB)"
                else
                    filename *= "-ngram=none"
                end
                if params.GOAL_PRIOR_TYPE in (:categorical, :ngram)
                    filename *= "-word_temp=$(params.NGRAM_TEMPERATURE)"
                    filename *= "-word_mult=$(params.NGRAM_MULTIPLIER)"
                end
                filename *= "-act_temp=$(params.ACT_TEMPERATURE)"
                filename *= "-search=$(params.SEARCH_METHOD)"
                filename *= "-max_nodes=$(params.MAX_NODES)"
                filename *= "-replan_period=$(params.REPLAN_PERIOD)"                
            elseif params.METHOD == :open_ended
                filename *= "-$(params.PROPOSAL_TYPE)"
                filename *= "-prior=$(params.GOAL_PRIOR_TYPE)"
                filename *= "-ngram=$(params.NGRAM_VOCAB)"
                filename *= "-$(params.NGRAM_TEMPERATURE)"
                filename *= "-$(params.NGRAM_MULTIPLIER)"
                filename *= "-$(params.NGRAM_EPSILON)"
                filename *= "-act_temp=$(params.ACT_TEMPERATURE)"
                filename *= "-search=$(params.SEARCH_METHOD)"
                filename *= "-max_nodes=$(params.MAX_NODES)"
                filename *= "-replan_period=$(params.REPLAN_PERIOD)"
                filename *= "-n_samples=$(N_ADD_PARTICLES)"
            elseif params.METHOD == :proposal_only
                filename *= "-$(params.PROPOSAL_TYPE)"
                filename *= "-ngram=$(params.NGRAM_VOCAB)"
                filename *= "-$(params.NGRAM_TEMPERATURE)"
                filename *= "-$(params.NGRAM_MULTIPLIER)"
                filename *= "-$(params.NGRAM_EPSILON)"
                filename *= "-n_samples=$(N_ADD_PARTICLES)"
            end
            if n_trials > 1
                filename *= "-$trial_id"
            end
            results_path = joinpath(subdir, filename * ".json")
            open(results_path, "w") do io
                JSON3.pretty(io, data, JSON3.AlignmentContext(indent=2))
            end
            println()

            # Force garbage collection
            GC.gc()
        end
    end
end

