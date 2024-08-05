using PDDL, SymbolicPlanners
using Gen, GenParticleFilters
using InversePlanning
using JSON3

using DataStructures: OrderedDict

include("src/plan_io.jl")
include("src/utils.jl")
include("src/inference.jl")

# Define directory paths
PROBLEM_DIR = joinpath(@__DIR__, "dataset", "problems")
PLAN_DIR = joinpath(@__DIR__, "dataset", "plans")
STIMULI_DIR = joinpath(@__DIR__, "dataset", "stimuli")
RESULTS_DIR = joinpath(@__DIR__, "results")
mkpath(RESULTS_DIR)

# Load domain, problem, and plan
domain = load_domain(joinpath(@__DIR__, "dataset", "domain.pddl"))

problem_path = joinpath(PROBLEM_DIR, "problem-irrational-1.pddl")
problem = load_problem(problem_path)

plan_path = joinpath(PLAN_DIR, "plan-irrational-1.pddl")
plan, _, splitpoints = load_plan(plan_path) 

# Initialize state and construct goal specification
state = initstate(domain, problem)
spec = Specification(problem)

# Compile domain for faster performance
domain, state = PDDL.compiled(domain, state)

# Configure model with uniform goal prior
world_config, goal_space = configure_model(
    domain, state, goal_prior_type=:uniform,
    max_nodes = 50, act_temperature=1.0
)

# Run enumerative SIPS
pf_state, data = run_enumerative_sips(
    domain, state, plan,
    world_config, goal_space,
    split_idxs=splitpoints
)

# Save data to JSON file
data[:goal_space] = goal_space
data = sort(data, by = x -> (length(string(x)), x))
stim_name = replace(splitext(basename(plan_path))[1], "plan-" => "")
results_path = joinpath(RESULTS_DIR, "results-enumerative-$(stim_name).json")
open(results_path, "w") do io
    JSON3.pretty(io, data, JSON3.AlignmentContext(indent=2))
end

# Configure model with uniform goal prior
world_config, goal_space = configure_model(
    domain, state, goal_prior_type = :categorical,
    max_nodes = 50, act_temperature = 1.0,
    goal_prior_kwargs = (
        multiplier = 100, temperature = 2.5, vocab = WORD_FREQS
    )
)

# Set up ngram distribution for proposals
ngram_dist = construct_ngram_dist(
    domain, state;
    vocab = WORD_FREQS, n = 5, multiplier = 100, temperature = 2.5
)
# Select goal proposal
goal_proposal = chained_tower_proposal

# Run open-ended SIPS
n_particles = 5
pf_state, data = run_open_ended_sips(
    domain, state, plan,
    world_config, goal_space, n_particles,
    split_idxs = splitpoints,
    goal_proposal = goal_proposal,
    ngram_dist = ngram_dist,
    rejuvenation = :always
);

# Save data to JSON file
data[:goal_space] = goal_space
data = sort(data, by = x -> (length(string(x)), x))
stim_name = replace(splitext(basename(plan_path))[1], "plan-" => "")
results_path = joinpath(RESULTS_DIR, "results-open_ended-$(stim_name).json")
open(results_path, "w") do io
    JSON3.pretty(io, data, JSON3.AlignmentContext(indent=2))
end

# Run proposal-only inference
n_particles = 10
pf_state, data = run_proposal_only(
    domain, state, plan,
    world_config, goal_space, n_particles,
    split_idxs=splitpoints
)

# Save data to JSON file
data[:goal_space] = goal_space
data = sort(data, by = x -> (length(string(x)), x))
stim_name = replace(splitext(basename(plan_path))[1], "plan-" => "")
results_path = joinpath(RESULTS_DIR, "results-proposal-$(stim_name).json")
open(results_path, "w") do io
    JSON3.pretty(io, data, JSON3.AlignmentContext(indent=2))
end

# Manually garbage collect to free up memory
GC.gc()
