using JSON3
using CSV, DataFrames
using Statistics, StatsBase
using PDDL

include("src/ngrams.jl")
include("src/plan_io.jl")
include("src/utils.jl")

RESULTS_DIR = joinpath(@__DIR__, "results")
HUMAN_RESULTS_DIR = joinpath(RESULTS_DIR, "humans")
MODEL_RESULTS_DIR = joinpath(RESULTS_DIR, "models")

PROBLEM_DIR = joinpath(@__DIR__, "dataset", "problems")
PLAN_DIR = joinpath(@__DIR__, "dataset", "plans")

WORDS = load_word_list(joinpath(@__DIR__, "assets", "words.txt"))
POSSIBLE_WORDS = Dict{String, Vector{String}}()
GOAL_WORDS = Dict{String, String}()

PLAN_IDS, _, _, SPLITPOINTS = load_plan_dataset(PLAN_DIR)

## Define utility functions ##

function get_possible_words(
    plan_id::AbstractString;
    min_chars=3, max_chars=8, vocab=WORDS, problem_dir=PROBLEM_DIR
)
    problem = load_problem(joinpath(problem_dir, "problem-$plan_id.pddl"))
    chars = [string(obj) for obj in PDDL.get_objects(problem)]
    chars = join(chars)
    vocab = filter_vocab(vocab, chars)
    for word in keys(vocab)
        min_chars <= length(word) <= max_chars || delete!(vocab, word)
    end
    possible_words = sort!(collect(keys(vocab)))
    return possible_words
end

for id in PLAN_IDS
    POSSIBLE_WORDS[id] = get_possible_words(id)
end

function get_goal_word(plan_id::AbstractString)
    problem = load_problem(joinpath(PROBLEM_DIR, "problem-$plan_id.pddl"))
    goal = problem.goal
    return terms_to_word(goal)
end

for id in PLAN_IDS
    GOAL_WORDS[id] = get_goal_word(id)
end

function get_top_k(k::Int)
    function _get_top_k(plan_ids, goal_probs...)
        goal_probs = reduce(hcat, goal_probs)
        replace!(goal_probs, missing => -Inf)
        top_k_idxs = map(eachrow(goal_probs)) do probs
            idxs = sortperm(probs, rev=true)[1:k]
            return idxs
        end
        top_k_goals = [permutedims(POSSIBLE_WORDS[plan_ids[i]][idxs])
                       for (i, idxs) in enumerate(top_k_idxs)]
        top_k_goals = reduce(vcat, top_k_goals)
        top_k_goals = DataFrame(top_k_goals, ["top_$(i)_goal" for i in 1:k])
        top_k_probs = [ps[idxs]' for (idxs, ps) in
                       zip(top_k_idxs, eachrow(goal_probs))]
        top_k_probs = reduce(vcat, top_k_probs)
        top_k_probs = DataFrame(top_k_probs, ["top_$(i)_prob" for i in 1:k])
        df = hcat(top_k_goals, top_k_probs)
        df.top_k_idxs = top_k_idxs
        return df
    end
    return _get_top_k
end

function select_top_k(top_k_idxs, cols...)
    cols = reduce(hcat, cols)
    cols = map(enumerate(eachrow(cols))) do (i, row)
        permutedims(row[top_k_idxs[i]])
    end
    return reduce(vcat, cols)
end

"""
    sim_with(f::Function, x::AbstractMatrix; per_row=true)

Returns a function `sim_with_x(col_counts, cols...)` that computes similarity
of a  set of vectors `cols` according to a function `f` with an input matrix `x`.
"""
function sim_with(f::Function, x::AbstractMatrix; per_row=true)
    function sim_with_x(col_counts, cols::AbstractVector...)
        y = stack(cols)
        return sim_with_x(col_counts, y)
    end
    function sim_with_x(col_counts, y::AbstractMatrix)
        x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachrow(x), col_counts))
        y_rows = (@view(vs[1:n]) for (vs, n) in zip(eachrow(y), col_counts))
        if per_row
            return [f(y, x) for (x, y) in zip(x_rows, y_rows)]
        else
            return f(reduce(vcat, y_rows), reduce(vcat, x_rows))
        end
    end
    return sim_with_x
end

"""
    sim_ci_with(f::Function, xs::Vector; per_row=true)

Returns a function `sim_ci_with_xs(col_counts, cols...)` that computes a
95% confidence interval for the similarity of a set of vectors `cols`, where
similarity is computed according to a function `f` against each element `x`
of a set of samples `xs`.
"""
function sim_ci_with(f::Function, xs::Vector; per_row=true, x_permuted=true)
    function sim_ci_with_xs(col_counts, cols::AbstractVector...)
        y = stack(cols)
        return sim_ci_with_xs(col_counts, y)
    end
    function sim_ci_with_xs(col_counts, y::AbstractMatrix)
        y_rows = map(zip(eachrow(y), col_counts)) do (vs, n)
            return vs[1:n]
        end
        if per_row
            all_sims = map(xs) do x
                if x_permuted
                    x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachcol(x), col_counts))
                    return [f(y, x) for (x, y) in zip(x_rows, y_rows)]
                else
                    x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachrow(x), col_counts))
                    return [f(y, x) for (x, y) in zip(x_rows, y_rows)]
                end
            end
            all_sims = reduce(hcat, all_sims)
            lo = map(eachrow(all_sims)) do sims
                any(ismissing.(sims)) && return missing
                any(isnan.(sims)) && return NaN
                return quantile(sims, 0.025)
            end
            hi = map(eachrow(all_sims)) do sims
                any(ismissing.(sims)) && return missing
                any(isnan.(sims)) && return NaN
                return quantile(sims, 0.975)
            end
            return hcat(lo, hi)
        else
            all_sims = Vector{Float64}(undef, length(xs))
            ys = reduce(vcat, y_rows)
            for i in eachindex(xs)
                if x_permuted
                    x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachcol(xs[i]), col_counts))
                    all_sims[i] = f(ys, reduce(vcat, x_rows))
                else
                    x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachrow(xs[i]), col_counts))
                    all_sims[i] = f(ys, reduce(vcat, x_rows))
                end
            end
            any(ismissing.(all_sims)) && return [missing missing]
            any(isnan.(all_sims)) &&  return [NaN NaN]
            return quantile(all_sims, [0.025, 0.975])'
        end
    end
    return sim_ci_with_xs
end

"""
    sim_se_with(f::Function, xs::Vector; per_row=true)

Returns a function `sim_se_with_xs(col_counts, cols...)` that computes the
standard error of the similarity of a set of vectors `cols`, where similarity is
computed according to a function `f` against each element `x` of a set
of samples `xs`.
"""
function sim_se_with(f::Function, xs::Vector; per_row=true, x_permuted=true)
    function sim_se_with_xs(col_counts, cols::AbstractVector...)
        y = stack(cols)
        return sim_se_with_xs(col_counts, y)
    end
    function sim_se_with_xs(col_counts, y::AbstractMatrix)
        y_rows = map(zip(eachrow(y), col_counts)) do (vs, n)
            return @view vs[1:n]
        end
        if per_row
            all_sims = map(xs) do x
                if x_permuted
                    x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachcol(x), col_counts))
                    return [f(y, x) for (x, y) in zip(x_rows, y_rows)]
                else
                    x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachrow(x), col_counts))
                    return [f(y, x) for (x, y) in zip(x_rows, y_rows)]
                end
            end
            all_sims = reduce(hcat, all_sims)
            return map(eachrow(all_sims)) do sims
                any(ismissing.(sims)) && return missing
                return std(sims)
            end
        else
            all_sims = Vector{Float64}(undef, length(xs))
            ys = reduce(vcat, y_rows)
            for i in eachindex(xs)
                if x_permuted
                    x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachcol(xs[i]), col_counts))
                    all_sims[i] = f(ys, reduce(vcat, x_rows))
                else
                    x_rows = (@view(vs[1:n]) for (vs, n) in zip(eachrow(xs[i]), col_counts))
                    all_sims[i] = f(ys, reduce(vcat, x_rows))
                end
            end
            any(ismissing.(all_sims)) && return missing
            return std(all_sims)
        end
    end
    return sim_se_with_xs
end

"Overlap of two probability vectors."
overlap(a, b) = sum(min.(a, b))

"Total variation of two probability vectors."
total_variation(a, b) = sum(abs.(a .- b)) / 2

"Intersection over union of two vectors."
iou(a, b) = sum(min.(a, b)) ./ sum(max.(a, b))

## Load and process human data ##

# Load Firebase data
firebase_path = joinpath(HUMAN_RESULTS_DIR, "firebase_data.json")
firebase_data = JSON3.read(read(firebase_path, String))

# Load Qualtrics data
qualtrics_path = joinpath(HUMAN_RESULTS_DIR, "qualtrics_data.csv")
qualtrics_data = CSV.read(qualtrics_path, DataFrame, header=2, skipto=4)

# Extract experiment completion codes generated by Firebase app
participant_codes = qualtrics_data[:, "Experiment-Code"]

# Extract Firebase entries and entry names
entries = firebase_data.results
entry_names = string.(collect(keys(firebase_data.results)))

# Extract global participant data
participant_df = DataFrame()
for (idx, code) in enumerate(participant_codes)
    row = Dict()
    entry = entries[Symbol(code)]
    row[:participant_code] = code
    # Add exam score
    row[:exam_results] = entry.exam.results
    row[:exam_score] = entry.exam.score
    # Add total reward
    row[:total_reward] = parse(Float64, entry.total_reward)
    # Add total payment
    row[:total_payment] = parse(Float64, entry.total_payment)
    # Add duration
    row[:duration] = qualtrics_data[idx, "Duration (in seconds)"] ./ 60
    push!(participant_df, row; cols=:union)
end

# Add Prolific IDs
prolific_id = qualtrics_data[:, "Prolific-ID"]
participant_df.prolific_id = prolific_id

# Print bonus for bulk payment on Prolific
for row in eachrow(participant_df)
    if row.total_payment <= 0.0 continue end
    println(row.prolific_id, ", ", round(row.total_payment, digits=2))
end

# Write participant data to CSV
CSV.write(joinpath(HUMAN_RESULTS_DIR, "participant_data.csv"), participant_df)

# Extract main experiment data
human_df = DataFrame(
    "participant_code" => Int[],
    "plan_id" => String[],
    "condition" => String[],
    "cond_id" => Int[],
    "step" => Int[],
    "timestep" => Int[],
    "guesses" => Vector{String}[],
    "n_correct" => Int[],
    "n_guesses" => Int[],
    "reward" => Float64[],
    "time_spent" => Float64[],
    "n_goals" => Int[],
    "true_goal_probs" => Float64[],
    ["goal_probs_$i" => Float64[] for i in 1:1000]...
)

n_skipped = 0
n_stims_skipped = 0
n_stims_no_adjust = 0
n_stims_only_add = 0
for code in participant_codes
    participant_entry = entries[Symbol(code)]
    for (name, stim_entry) in pairs(participant_entry)
        # Extract only entries of the form plan-<condition>-<id>
        m = match(r"plan-(\w+)-(\d+)", string(name))
        isnothing(m) && continue
        condition = m.captures[1]
        cond_id = parse(Int, m.captures[2])
        plan_id = "$condition-$cond_id"
        possible_words = POSSIBLE_WORDS[plan_id]
        # Filter out responses where participant does not change guesses
        all_guesses = [(k, r[:guesses]) for (k, r) in pairs(stim_entry) if k != :reward]
        sort!(all_guesses, by=first)
        all_guesses = last.(all_guesses)
        if allequal(all_guesses)
            println("Participant $code did not adjust guesses for $plan_id, skipping...")
            n_skipped += length(all_guesses)
            n_stims_skipped += 1
            n_stims_no_adjust += 1
            continue
        end
        # Filter out responses where participants only add guesses
        if all(length(g[i]) <= length(g[i+1]) && g[i] == g[i+1][1:length(g[i])] for g in all_guesses for i in 1:length(g)-1)
            println("Participant $code only added guesses for $plan_id, skipping...")
            n_skipped += length(all_guesses)
            n_stims_skipped += 1
            n_stims_only_add += 1
            continue
        end
        for (step, stim_row) in pairs(stim_entry)
            string(step) == "reward" && continue
            row = Dict{Symbol, Any}()
            row[:step] = parse(Int, (String(step))) + 1
            row[:participant_code] = code
            row[:plan_id] = plan_id
            row[:condition] = condition
            row[:cond_id] = cond_id
            for (key, val) in stim_row
                if val isa AbstractArray
                    row[key] = collect(val)
                elseif val isa Real
                    row[key] = val
                else
                    row[key] = parse(Float64, val)
                end
            end
            row[:n_goals] = length(possible_words)
            row[:true_goal_probs] = row[:reward]
            goal_probs = zeros(1000)
            n_guesses = row[:n_guesses]
            for guess in row[:guesses]
                idx = findfirst(isequal(guess), possible_words)
                if !isnothing(idx)
                    goal_probs[idx] += 1
                end
            end
            goal_probs ./= n_guesses
            for (i, p) in enumerate(goal_probs)
                row[Symbol("goal_probs_$i")] = p
            end
            push!(human_df, row; cols=:union)
        end
    end
end
sort!(human_df, [:participant_code, :condition, :cond_id, :timestep])

# Write experiment data to CSV
CSV.write(joinpath(HUMAN_RESULTS_DIR, "human_data.csv"), human_df)

# Compute average number of guesses per participant
group_df = DataFrames.groupby(human_df, [:participant_code])
n_guesses_df = combine(group_df, 
    "reward" => sum => "reward",
    "n_guesses" => mean => "n_guesses",
    "n_guesses" => maximum => "max_guesses",
    "n_guesses" => minimum => "min_guesses",
    "n_guesses" => median => "med_guesses",
    "n_guesses" => (x -> quantile(x, 0.25)) => "q1_guesses",
    "n_guesses" => (x -> quantile(x, 0.75)) => "q3_guesses",
)

# Summarize data by stimulus
group_df = DataFrames.groupby(human_df, [:plan_id, :condition, :cond_id, :timestep])
mean_human_df = combine(group_df,
    nrow => "n_trials",
    "n_guesses" => mean => "n_guesses",
    "n_guesses" => std => "n_guesses_std",    
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs" => std => "true_goal_probs_std",
    "n_goals" => (x -> round(Int, mean(x))) => "n_goals",
    ["goal_probs_$i" => mean => "goal_probs_$i" for i in 1:1000]...,
    ["goal_probs_$i" => std => "goal_probs_std_$i" for i in 1:1000]...,
)
sort!(mean_human_df, [:plan_id, :condition, :cond_id, :timestep])

# Compute top k goals by probabliity
transform!(mean_human_df,
    ["plan_id"; ["goal_probs_$i" for i in 1:1000]] => get_top_k(5) => AsTable,
)
transform!(mean_human_df,
    ["top_k_idxs"; ["goal_probs_std_$i" for i in 1:1000]] => select_top_k => ["top_$(i)_goal_std" for i in 1:5],
)

select!(mean_human_df,
    :plan_id, :condition, :cond_id, :timestep, :n_trials,
    :n_guesses, :n_guesses_std, :true_goal_probs, :true_goal_probs_std,
    :n_goals, r"top_\d+_goal$", r"top_\d+_prob$", r"top_\d+_goal_std",
    r"goal_probs_\d+", r"goal_probs_std_\d+"
)

# Write aggregated data per stimulus to CSV
CSV.write(joinpath(HUMAN_RESULTS_DIR, "mean_human_data.csv"), mean_human_df)

## Human self-correlation analysis ##

# Compute inter-human per-step correlations via 50-50 random splits
human_corr_per_step_df = DataFrame()
human_corr_per_cond_df = DataFrame()
human_corr_df = DataFrame()

n_participants = length(unique(human_df.participant_code))
participant_codes = sort!(unique(human_df.participant_code))

# 100 random 50-50 splits
for run in 1:100
    codes_1 = sample(participant_codes, n_participants ÷ 2, replace=false)
    codes_2 = setdiff(participant_codes, codes_1)

    human_df_1 = filter(r -> r.participant_code in codes_1, human_df)
    mean_human_df_1 = combine(
        groupby(human_df_1, [:plan_id, :condition, :cond_id, :timestep]),
        "n_goals" => (x -> round(Int, mean(x))) => "n_goals",
        ["goal_probs_$i" => mean => "goal_probs_$i" for i in 1:1000]...,
    )
    sort!(mean_human_df_1, [:plan_id, :condition, :cond_id, :timestep])
    @assert nrow(mean_human_df_1) == nrow(mean_human_df)
    mean_human_df_1.judgment_id = 1:nrow(mean_human_df_1)

    human_df_2 = filter(r -> r.participant_code in codes_2, human_df)
    mean_human_df_2 = combine(
        groupby(human_df_2, [:plan_id, :condition, :cond_id, :timestep]),
        "n_goals" => (x -> round(Int, mean(x))) => "n_goals",
        ["goal_probs_$i" => mean => "goal_probs_$i" for i in 1:1000]...,
    )
    sort!(mean_human_df_2, [:plan_id, :condition, :cond_id, :timestep])
    @assert nrow(mean_human_df_2) == nrow(mean_human_df)
    mean_human_df_2.judgment_id = 1:nrow(mean_human_df_2)

    # Compute self-correlation/agreement per judgement point
    mean_probs_1 = mean_human_df_1[:, r"goal_probs_\d+$"] |> Matrix
    df = combine(
        mean_human_df_2,
        "plan_id" => identity => "plan_id",
        "condition" => identity => "condition",
        "cond_id" => identity => "cond_id",
        "timestep" => identity => "timestep",
        ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(cor, mean_probs_1) => "goal_cor",
        ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(overlap, mean_probs_1) => "goal_overlap",
        ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(total_variation, mean_probs_1) => "goal_tv",
        ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(iou, mean_probs_1) => "goal_iou",    
    )
    df.run .= run
    append!(human_corr_per_step_df, df, cols=:union)

    # Compute self-correlation per condition
    cond_df = DataFrame()
    gdf = groupby(mean_human_df_2, [:condition])
    for group in gdf
        m_probs = mean_probs_1[group.judgment_id, :]
        new_df = combine(group,
            "condition" => first => "condition",
            ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(cor, m_probs, per_row=false) => "goal_cor",
            ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(overlap, m_probs, per_row=false) => "goal_overlap",
            ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(total_variation, m_probs, per_row=false) => "goal_tv",
            ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(iou, m_probs, per_row=false) => "goal_iou",
        )
        # Normalize overlap and total variation by number of ratings per group
        new_df[!, "goal_overlap"] ./= nrow(group)
        new_df[!, "goal_tv"] ./= nrow(group)
        append!(cond_df, new_df, cols=:union)
    end
    append!(human_corr_per_cond_df, cond_df, cols=:union)

    # Compute correlation across entire dataset
    full_df = combine(mean_human_df_2,
        ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(cor, mean_probs_1, per_row=false) => "goal_cor",
        ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(overlap, mean_probs_1, per_row=false) => "goal_overlap",
        ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(total_variation, mean_probs_1, per_row=false) => "goal_tv",
        ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(iou, mean_probs_1, per_row=false) => "goal_iou",
    )

    # Normalize overlap and total variation by number of ratings
    full_df[!, "goal_overlap"] ./= nrow(mean_human_df_2)
    full_df[!, "goal_tv"] ./= nrow(mean_human_df_2)
    append!(human_corr_df, full_df, cols=:union)
end

human_corr_per_step_df = combine(
    groupby(human_corr_per_step_df, [:plan_id, :condition, :timestep]),
    "goal_cor" => mean => "goal_cor",
    "goal_cor" => std => "goal_cor_se",
    "goal_overlap" => mean => "goal_overlap",
    "goal_overlap" => std => "goal_overlap_se",
    "goal_tv" => mean => "goal_tv",
    "goal_tv" => std => "goal_tv_se",
    "goal_iou" => mean => "goal_iou",
    "goal_iou" => std => "goal_iou_se",
)
CSV.write(joinpath(RESULTS_DIR, "human_corr_per_step.csv"), human_corr_per_step_df)

human_corr_per_cond_df = combine(
    groupby(human_corr_per_cond_df, [:condition]),
    "goal_cor" => mean => "goal_cor",
    "goal_cor" => std => "goal_cor_se",
    "goal_overlap" => mean => "goal_overlap",
    "goal_overlap" => std => "goal_overlap_se",
    "goal_tv" => mean => "goal_tv",
    "goal_tv" => std => "goal_tv_se",
    "goal_iou" => mean => "goal_iou",
    "goal_iou" => std => "goal_iou_se",
)
CSV.write(joinpath(RESULTS_DIR, "human_corr_per_cond.csv"), human_corr_per_cond_df)

human_corr_df = combine(
    human_corr_df,
    "goal_cor" => mean => "goal_cor",
    "goal_cor" => std => "goal_cor_se",
    "goal_overlap" => mean => "goal_overlap",
    "goal_overlap" => std => "goal_overlap_se",
    "goal_tv" => mean => "goal_tv",
    "goal_tv" => std => "goal_tv_se",
    "goal_iou" => mean => "goal_iou",
    "goal_iou" => std => "goal_iou_se",
)
CSV.write(joinpath(RESULTS_DIR, "human_corr.csv"), human_corr_df)

## Load and process model data ##

using DataStructures: OrderedDict

# Load results for enumerative SIPS
enumerative_df = DataFrame(
    "plan_id" => String[],
    "condition" => String[],
    "cond_id" => Int[],
    "method" => String[],
    "goal_prior_type" => String[],
    "act_temperature" => Float64[],
    "search_method" => String[],
    "max_nodes" => Int[],
    "replan_period" => Int[],
    "proposal_type" => String[],
    "n_init_particles" => Int[],
    "n_add_particles" => Int[],
    "ngram_vocab" => Int[],
    "ngram_size" => Int[],
    "ngram_multiplier" => Float64[],
    "ngram_temperature" => Float64[],
    "step" => Int[],
    "timestep" => Int[],
    "is_judgment" => Bool[],
    "action" => String[],
    "runtime" => Float64[],
    "runtime_per_step" => Float64[],
    "runtime_per_act" => Float64[],
    "n_guesses" => Float64[],
    "ess" => Float64[],
    "lml_est" => Float64[],
    "n_goals" => Int[],
    "true_goal_probs" => Float64[],
    ["top_$(i)_goal" => String[] for i in 1:5]...,
    ["top_$(i)_prob" => Float64[] for i in 1:5]...,
    ["goal_probs_$i" => Float64[] for i in 1:1000]...,
    ["goal_probs_std_$i" => Float64[] for i in 1:1000]...
)

json_paths = readdir(joinpath(RESULTS_DIR, "enumerative"), join=true)
filter!(json_paths) do path
    m = match(r"results-(\w+)-(\w+)-(\d+)-prior=(\w+)-ngram=(\w+)-(?:word_temp=[0-9]*\.?[0-9]+-word_mult=[0-9]*\.?[0-9]+-)?act_temp=([0-9]*\.?[0-9]+)-search=(\w+)-max_nodes=(\d+)-replan_period=(\d+).json", basename(path))
    return !isnothing(m)
end

for path in json_paths
    json = JSON3.read(read(path, String))
    m = match(r"results-(\w+)-(\w+)-(\d+)-prior=(\w+)-ngram=(\w+)-(?:word_temp=[0-9]*\.?[0-9]+-word_mult=[0-9]*\.?[0-9]+-)?act_temp=([0-9]*\.?[0-9]+)-search=(\w+)-max_nodes=(\d+)-replan_period=(\d+).json", basename(path))
    if isnothing(m)
        println("Skipping: $(basename(path))")
        continue
    end
    condition = m.captures[2]
    cond_id = parse(Int, m.captures[3])
    plan_id = "$condition-$cond_id"
    n_steps = length(json[:t])
    splitpoints = SPLITPOINTS[plan_id]
    new_df = DataFrame(
        "plan_id" => fill(plan_id, n_steps),
        "condition" => fill(condition, n_steps),
        "cond_id" => fill(cond_id, n_steps),
        # "trial_id" => 1,
        "step" => 1:n_steps,
        "timestep" => json[:t],
        "is_judgment" => [t in splitpoints for t in json[:t]],
        "runtime" => json[:time] .- json[:t_start],
        "action" => json[:act],
        "ess" => json[:ess],
        "lml_est" => json[:lml_est],
    )
    new_df[:, "n_goals"] .= length(json[:goal_space])
    new_df[:, "n_guesses"] .= length(json[:goal_space])
    # Add model configuration
    for (key, val) in json[:config]
        new_df[:, key] .= val
    end
    # Add top k goals
    top_k_goals = map(json[:top_k_goals]) do goals
        if length(goals) < 5
            goals = [goals; fill("", 5 - length(goals))]
        end
        return permutedims(goals)
    end
    top_k_goals = reduce(vcat, top_k_goals)
    for (i, goals) in enumerate(eachcol(top_k_goals))
        new_df[:, "top_$(i)_goal"] .= goals
    end
    # Add top k probabilities
    top_k_probs = map(json[:top_k_probs]) do probs
        if length(probs) < 5
            probs = [probs; fill(0.0, 5 - length(probs))]
        end
        return permutedims(probs)
    end
    top_k_probs = reduce(vcat, top_k_probs)
    for (i, probs) in enumerate(eachcol(top_k_probs))
        new_df[:, "top_$(i)_prob"] .= probs
    end
    # Add all goal probabilities
    goal_probs = permutedims(reduce(hcat, json[:goal_probs]))
    for (i, probs) in enumerate(eachcol(goal_probs))
        new_df[:, "goal_probs_$i"] .= probs
        new_df[:, "goal_probs_std_$i"] .= 0.0
    end
    # Add true goal probabilities
    true_goal_word = GOAL_WORDS[plan_id]
    true_goal_idx = findfirst(==(true_goal_word), json[:goal_space])
    new_df[:, "true_goal_probs"] .= goal_probs[:, true_goal_idx]
    # Add runtime per step
    new_df[:, "runtime_per_step"] .= pushfirst!(diff(new_df.runtime), 0.0)
    acts_per_step = pushfirst!(diff(new_df[:, "timestep"]), 1)
    new_df[:, "runtime_per_act"] .= new_df[:, "runtime_per_step"] ./ acts_per_step
    # Append to main dataframe
    append!(enumerative_df, new_df, cols=:union)
end
sort!(enumerative_df, [:goal_prior_type, :ngram_multiplier, :ngram_temperature,
                       :search_method, :max_nodes, :replan_period,
                       :plan_id, :condition, :cond_id, :timestep])

# Save results
CSV.write(joinpath(MODEL_RESULTS_DIR, "enumerative.csv"), enumerative_df)

# Compute average goal accuracy and runtime across parameters
df = filter(r -> r.is_judgment, enumerative_df)
gdf = groupby(df,
    [:goal_prior_type, :ngram_multiplier, :ngram_temperature,
     :search_method, :max_nodes, :replan_period, :act_temperature]
)
performance_df = combine(gdf,
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_step" => mean => "runtime_per_step",
    "true_goal_probs" => mean => "true_goal_probs",
)

# Compute log marginal likelihood of dataset for each configuration
gdf = groupby(enumerative_df,
    [:goal_prior_type, :ngram_multiplier, :ngram_temperature,
     :search_method, :max_nodes, :replan_period, :act_temperature, :plan_id]
)
lml_df = combine(gdf, "lml_est" => (x -> parse(Float64, last(x))) => "lml_est")
gdf = groupby(lml_df,
    [:goal_prior_type, :ngram_multiplier, :ngram_temperature,
     :search_method, :max_nodes, :replan_period, :act_temperature]
)
lml_df = combine(gdf, "lml_est" => sum => "lml_est")
performance_df.lml_est = lml_df.lml_est

CSV.write(joinpath(RESULTS_DIR, "performance_enumerative.csv"), performance_df)

# Compute average goal accuracy per condition
gdf = groupby(df,
    [:condition, :goal_prior_type, :ngram_multiplier, :ngram_temperature,
     :search_method, :max_nodes, :replan_period, :act_temperature]
)
performance_per_cond_df = combine(gdf,
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_step" => mean => "runtime_per_step",
    "true_goal_probs" => mean => "true_goal_probs",
    "lml_est" => (x -> parse.(Float64, x) |> mean) => "lml_est"
)
performance_df.condition .= "all"
append!(performance_per_cond_df, performance_df)
sort!(performance_per_cond_df,
    [:condition, :goal_prior_type, :ngram_multiplier, :ngram_temperature, 
     :search_method, :max_nodes, :replan_period])
CSV.write(joinpath(RESULTS_DIR, "performance_enumerative_per_cond.csv"), performance_per_cond_df)

## Open-ended SIPS ##

# Load results for open-ended SIPS
open_ended_df = DataFrame(
    "plan_id" => String[],
    "condition" => String[],
    "cond_id" => Int[],
    "trial_id" => Int[],
    "method" => String[],
    "goal_prior_type" => String[],
    "act_temperature" => Float64[],
    "max_nodes" => Int[],
    "replan_period" => Int[],
    "proposal_type" => String[],
    "n_init_particles" => Int[],
    "n_add_particles" => Int[],
    "ngram_vocab" => Int[],
    "ngram_size" => Int[],
    "ngram_multiplier" => Float64[],
    "ngram_temperature" => Float64[],
    "ngram_epsilon" => Float64[],
    "step" => Int[],
    "timestep" => Int[],
    "is_judgment" => Bool[],
    "action" => String[],
    "runtime" => Float64[],
    "runtime_per_step" => Float64[],
    "runtime_per_act" => Float64[],
    "n_guesses" => Float64[],
    "ess" => Float64[],
    "lml_est" => Float64[],
    "n_goals" => Int[],
    "true_goal_probs" => Float64[],
    ["top_$(i)_goal" => String[] for i in 1:5]...,
    ["top_$(i)_prob" => Float64[] for i in 1:5]...,
    ["goal_probs_$i" => Float64[] for i in 1:1000]...
)

json_paths = readdir(joinpath(RESULTS_DIR, "open_ended"), join=true)
filter!(json_paths) do path
    m = match(r"^results-(\w+)-(\w+)-(\d+)-(\w+)-prior=(\w+)-ngram=(\w+)-([0-9]*\.?[0-9]+)-([0-9]*\.?[0-9]+)-([0-9]*\.?[0-9]+)-act_temp=([0-9]*\.?[0-9]+)-search=(\w+)-max_nodes=(\d+)-replan_period=(\d+)-n_samples=(\d+)-(\d+)\.json$", basename(path))
    return !isnothing(m)
end

for path in json_paths
    json = JSON3.read(read(path, String))
    m = match(r"^results-(\w+)-(\w+)-(\d+)-(\w+)-prior=(\w+)-ngram=(\w+)-([0-9]*\.?[0-9]+)-([0-9]*\.?[0-9]+)-([0-9]*\.?[0-9]+)-act_temp=([0-9]*\.?[0-9]+)-search=(\w+)-max_nodes=(\d+)-replan_period=(\d+)-n_samples=(\d+)-(\d+)\.json$", basename(path))
    if isnothing(m)
        println("Skipping: $(basename(path))")
        continue
    end
    condition = m.captures[2]
    cond_id = parse(Int, m.captures[3])
    plan_id = "$condition-$cond_id"
    trial_id = parse(Int, m.captures[end])
    n_steps = length(json[:t])
    splitpoints = SPLITPOINTS[plan_id]
    new_df = DataFrame(
        "plan_id" => fill(plan_id, n_steps),
        "condition" => fill(condition, n_steps),
        "cond_id" => fill(cond_id, n_steps),
        "trial_id" => fill(trial_id, n_steps),
        "step" => 1:n_steps,
        "timestep" => json[:t],
        "is_judgment" => [t in splitpoints for t in json[:t]],
        "runtime" => json[:time] .- json[:t_start],
        "action" => json[:act],
        "ess" => json[:ess],
        "lml_est" => json[:lml_est],
    )
    new_df[:, "n_goals"] .= length(json[:goal_space])
    # Add model configuration
    for (key, val) in json[:config]
        new_df[:, key] .= val
    end
    # Add top k goals
    top_k_goals = map(json[:top_k_goals]) do goals
        if length(goals) < 5
            goals = [goals; fill("", 5 - length(goals))]
        end
        return permutedims(goals)
    end
    top_k_goals = reduce(vcat, top_k_goals)
    for (i, goals) in enumerate(eachcol(top_k_goals))
        new_df[:, "top_$(i)_goal"] .= goals
    end
    # Add top k probabilities
    top_k_probs = map(json[:top_k_probs]) do probs
        if length(probs) < 5
            probs = [probs; fill(0.0, 5 - length(probs))]
        end
        return permutedims(probs)
    end
    top_k_probs = reduce(vcat, top_k_probs)
    for (i, probs) in enumerate(eachcol(top_k_probs))
        new_df[:, "top_$(i)_prob"] .= probs
    end
    # Add all goal probabilities
    goal_probs = permutedims(reduce(hcat, json[:goal_probs]))
    for (i, probs) in enumerate(eachcol(goal_probs))
        new_df[:, "goal_probs_$i"] .= probs
    end
    # Add true goal probabilities
    true_goal_word = GOAL_WORDS[plan_id]
    true_goal_idx = findfirst(==(true_goal_word), json[:goal_space])
    new_df[:, "true_goal_probs"] .= goal_probs[:, true_goal_idx]
    # Add number of guesses at each step
    new_df[:, "n_guesses"] .= vec(sum(goal_probs .> 0.0, dims=2))
    # Add runtime per step
    new_df[:, "runtime_per_step"] .= pushfirst!(diff(new_df.runtime), 0.0)
    acts_per_step = pushfirst!(diff(new_df[:, "timestep"]), 1)
    new_df[:, "runtime_per_act"] .= new_df[:, "runtime_per_step"] ./ acts_per_step
    # Append to main dataframe
    append!(open_ended_df, new_df, cols=:union)
end
sort!(open_ended_df, 
    [:goal_prior_type,
     :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
     :proposal_type, :n_add_particles,
     :search_method, :max_nodes, :replan_period,
     :plan_id, :condition, :cond_id, :trial_id, :timestep])

# Save results
CSV.write(joinpath(MODEL_RESULTS_DIR, "open_ended.csv"), open_ended_df)

# Average results across trials
group_df = groupby(open_ended_df,
    ["plan_id", "condition", "cond_id", "n_goals",
     "timestep", "is_judgment", "action",
     "method", "goal_prior_type", "act_temperature", "max_nodes",
     "search_method", "replan_period",
     "proposal_type", "n_add_particles", "ngram_size",
     "ngram_vocab", "ngram_multiplier", "ngram_temperature", "ngram_epsilon"]
)
mean_open_ended_df = combine(group_df,
    nrow => "n_trials",
    "runtime_per_step" => mean => "runtime_per_step",
    "runtime_per_step" => std => "runtime_per_step_std",
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_act" => std => "runtime_per_act_std",
    "n_guesses" => mean => "n_guesses",
    "n_guesses" => std => "n_guesses_std",
    "lml_est" => (x -> mean(parse.(Float64, x))) => "lml_est",
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs" => std => "true_goal_probs_std",
    ["goal_probs_$i" => mean => "goal_probs_$i" for i in 1:1000]...,
    ["goal_probs_$i" => std => "goal_probs_std_$i" for i in 1:1000]...
)
sort!(mean_open_ended_df, 
    [:goal_prior_type,
     :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
     :proposal_type, :n_add_particles,
     :search_method, :max_nodes, :replan_period,
     :plan_id, :condition, :cond_id, :timestep])

# Compute top k goals by mean probability
transform!(mean_open_ended_df,
    ["plan_id"; ["goal_probs_$i" for i in 1:1000]] => get_top_k(5) => AsTable,
)
transform!(mean_open_ended_df,
    ["top_k_idxs"; ["goal_probs_std_$i" for i in 1:1000]] => select_top_k => ["top_$(i)_goal_std" for i in 1:5],
)

# Reorder columns
select!(mean_open_ended_df,
    Not(Cols(r"top_\d+_goal$", r"top_\d+_prob$", r"top_\d+_goal_std$", 
             r"goal_probs_\d+$", r"goal_probs_std_\d+$")),
    r"top_\d+_goal$", r"top_\d+_prob$", r"top_\d+_goal_std$",
    r"goal_probs_\d+$", r"goal_probs_std_\d+$"
)

# Write to file 
CSV.write(joinpath(MODEL_RESULTS_DIR, "open_ended_mean.csv"), mean_open_ended_df)

# Compute average goal accuracy and runtime across parameters
df = filter(r -> r.is_judgment, mean_open_ended_df)
gdf = groupby(df,
    [:goal_prior_type,
     :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
     :search_method, # :max_nodes, :replan_period,
     :proposal_type, :n_add_particles]
)
performance_df = combine(gdf,
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_step" => mean => "runtime_per_step",
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs_std" => mean => "true_goal_probs_std",
    ["true_goal_probs_std", "n_trials"] => ((s, n) -> sqrt(sum(s .^ 2 ./ n)) / length(s)) => "true_goal_probs_sem"
)

# Compute log marginal likelihood of dataset for each configuration
gdf = groupby(mean_open_ended_df,
    [:goal_prior_type,
    :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
    :search_method, # :max_nodes, :replan_period,
    :proposal_type, :n_add_particles, :plan_id]
)
lml_df = combine(gdf, "lml_est" => (x -> last(x)) => "lml_est")
gdf = groupby(lml_df,
    [:goal_prior_type,
    :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
    :search_method, # :max_nodes, :replan_period,
    :proposal_type, :n_add_particles]
)
lml_df = combine(gdf, "lml_est" => sum => "lml_est")
performance_df.lml_est = lml_df.lml_est

CSV.write(joinpath(RESULTS_DIR, "performance_open_ended.csv"), performance_df)

# Compute average goal accuracy per condition
gdf = groupby(df,
    [:condition, :goal_prior_type,
     :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
     :search_method, # :max_nodes, :replan_period,
     :proposal_type, :n_add_particles]
)
performance_per_cond_df = combine(gdf,
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_step" => mean => "runtime_per_step",
    "lml_est" => mean => "lml_est",
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs_std" => mean => "true_goal_probs_std",
    ["true_goal_probs_std", "n_trials"] => ((s, n) -> sqrt(sum(s .^ 2 ./ n)) / length(s)) => "true_goal_probs_sem"
)
performance_df.condition .= "all"
append!(performance_per_cond_df, performance_df)
sort!(performance_per_cond_df,
    [:condition, :goal_prior_type,
     :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
     # :search_method, :max_nodes, :replan_period,
     :proposal_type, :n_add_particles]
)
CSV.write(joinpath(RESULTS_DIR, "performance_open_ended_per_cond.csv"), performance_per_cond_df)

## Proposal-only baseline ##

# Load results for proposal-only baseline
proposal_only_df = DataFrame(
    "plan_id" => String[],
    "condition" => String[],
    "cond_id" => Int[],
    "trial_id" => Int[],
    "method" => String[],
    "goal_prior_type" => String[],
    "act_temperature" => Float64[],
    "max_nodes" => Int[],
    "proposal_type" => String[],
    "n_init_particles" => Int[],
    "n_add_particles" => Int[],
    "ngram_vocab" => Int[],
    "ngram_size" => Int[],
    "ngram_multiplier" => Float64[],
    "ngram_temperature" => Float64[],
    "ngram_epsilon" => Float64[],
    "step" => Int[],
    "timestep" => Int[],
    "is_judgment" => Bool[],
    "action" => String[],
    "runtime" => Float64[],
    "runtime_per_step" => Float64[],
    "runtime_per_act" => Float64[],
    "n_guesses" => Float64[],
    "ess" => Float64[],
    "lml_est" => Float64[],
    "n_goals" => Int[],
    "true_goal_probs" => Float64[],
    ["top_$(i)_goal" => String[] for i in 1:5]...,
    ["top_$(i)_prob" => Float64[] for i in 1:5]...,
    ["goal_probs_$i" => Float64[] for i in 1:1000]...
)

json_paths = readdir(joinpath(RESULTS_DIR, "proposal_only"), join=true)
filter!(json_paths) do path
    m = match(r"^results-(\w+)-(\w+)-(\d+)-(\w+)-ngram=(\w+)-([0-9]*\.?[0-9]+)-([0-9]*\.?[0-9]+)-([0-9]*\.?[0-9]+)-n_samples=(\d+)-(\d+)\.json$", basename(path))
    return !isnothing(m)
end

for path in json_paths
    json = JSON3.read(read(path, String))
    m = match(r"^results-(\w+)-(\w+)-(\d+)-(\w+)-ngram=(\w+)-([0-9]*\.?[0-9]+)-([0-9]*\.?[0-9]+)-([0-9]*\.?[0-9]+)-n_samples=(\d+)-(\d+)\.json$", basename(path))
    condition = m.captures[2]
    cond_id = parse(Int, m.captures[3])
    plan_id = "$condition-$cond_id"
    trial_id = parse(Int, m.captures[end])
    n_steps = length(json[:t])
    splitpoints = SPLITPOINTS[plan_id]
    new_df = DataFrame(
        "plan_id" => fill(plan_id, n_steps),
        "condition" => fill(condition, n_steps),
        "cond_id" => fill(cond_id, n_steps),
        "trial_id" => fill(trial_id, n_steps),
        "step" => 1:n_steps,
        "timestep" => json[:t],
        "is_judgment" => [t in splitpoints for t in json[:t]],
        "runtime" => json[:time] .- json[:time][1],
        "action" => json[:act],
        "ess" => json[:ess],
        "lml_est" => json[:lml_est],
    )
    new_df[:, "n_goals"] .= length(json[:goal_space])
    # Add model configuration
    for (key, val) in json[:config]
        if key == :n_particles
            new_df[:, :n_add_particles] .= val
        else
            new_df[:, key] .= val
        end
    end
    # Add top k goals
    top_k_goals = map(json[:top_k_goals]) do goals
        if length(goals) < 5
            goals = [goals; fill("", 5 - length(goals))]
        end
        return permutedims(goals)
    end
    top_k_goals = reduce(vcat, top_k_goals)
    for (i, goals) in enumerate(eachcol(top_k_goals))
        new_df[:, "top_$(i)_goal"] .= goals
    end
    # Add top k probabilities
    top_k_probs = map(json[:top_k_probs]) do probs
        if length(probs) < 5
            probs = [probs; fill(0.0, 5 - length(probs))]
        end
        return permutedims(probs)
    end
    top_k_probs = reduce(vcat, top_k_probs)
    for (i, probs) in enumerate(eachcol(top_k_probs))
        new_df[:, "top_$(i)_prob"] .= probs
    end
    # Add all goal probabilities
    goal_probs = permutedims(reduce(hcat, json[:goal_probs]))
    for (i, probs) in enumerate(eachcol(goal_probs))
        new_df[:, "goal_probs_$i"] .= probs
    end
    # Add true goal probabilitie 
    true_goal_word = GOAL_WORDS[plan_id]
    true_goal_idx = findfirst(==(true_goal_word), json[:goal_space])
    new_df[:, "true_goal_probs"] .= goal_probs[:, true_goal_idx]
    # Add number of guesses at each step
    new_df[:, "n_guesses"] .= vec(sum(goal_probs .> 0.0, dims=2))
    # Add runtime per step
    new_df[:, "runtime_per_step"] .= pushfirst!(diff(new_df.runtime), 0.0)
    acts_per_step = pushfirst!(diff(new_df[:, "timestep"]), 1)
    new_df[:, "runtime_per_act"] .= new_df[:, "runtime_per_step"] ./ acts_per_step
    # Append to main dataframe
    append!(proposal_only_df, new_df, cols=:union)
end
sort!(proposal_only_df, 
     [:ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
      :proposal_type, :n_add_particles,
      :plan_id, :condition, :cond_id, :trial_id, :timestep])

# Save results
CSV.write(joinpath(MODEL_RESULTS_DIR, "proposal_only.csv"), proposal_only_df)

# Average results across trials
group_df = groupby(proposal_only_df,
    ["plan_id", "condition", "cond_id", "n_goals",
     "timestep", "is_judgment", "action",
     "method", "proposal_type", "n_add_particles", "ngram_size",
     "ngram_vocab", "ngram_multiplier", "ngram_temperature", "ngram_epsilon"]
)
mean_proposal_only_df = combine(group_df,
    nrow => "n_trials",
    "runtime_per_step" => mean => "runtime_per_step",
    "runtime_per_step" => std => "runtime_per_step_std",
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_act" => std => "runtime_per_act_std",
    "n_guesses" => mean => "n_guesses",
    "n_guesses" => std => "n_guesses_std",    
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs" => std => "true_goal_probs_std",
    ["goal_probs_$i" => mean => "goal_probs_$i" for i in 1:1000]...,
    ["goal_probs_$i" => std => "goal_probs_std_$i" for i in 1:1000]...
)
sort!(mean_proposal_only_df, 
     [:ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
      :proposal_type, :n_add_particles,
      :plan_id, :condition, :cond_id, :timestep])

# Compute top k goals by mean probability
transform!(mean_proposal_only_df,
    ["plan_id"; ["goal_probs_$i" for i in 1:1000]] => get_top_k(5) => AsTable,
)
transform!(mean_proposal_only_df,
    ["top_k_idxs"; ["goal_probs_std_$i" for i in 1:1000]] => select_top_k => ["top_$(i)_goal_std" for i in 1:5],
)

# Reorder columns
select!(mean_proposal_only_df,
    Not(Cols(r"top_\d+_goal", r"top_\d+_prob", r"top_\d+_goal_std", 
             r"goal_probs_\d+", r"goal_probs_std_\d+")),
    r"top_\d+_goal", r"top_\d+_prob", r"top_\d+_goal_std",
    r"goal_probs_\d+", r"goal_probs_std_\d+"
)

# Write to file 
CSV.write(joinpath(MODEL_RESULTS_DIR, "proposal_only_mean.csv"), mean_proposal_only_df)

# Compute average goal accuracy and runtime across parameters
df = filter(r -> r.is_judgment, mean_proposal_only_df)
gdf = groupby(df,
    [:ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
     :proposal_type, :n_add_particles]
)
performance_df = combine(gdf,
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_step" => mean => "runtime_per_step",
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs_std" => mean => "true_goal_probs_std",
    ["true_goal_probs_std", "n_trials"] => ((s, n) -> sqrt(sum(s .^ 2 ./ n)) / length(s)) => "true_goal_probs_sem"
)
CSV.write(joinpath(RESULTS_DIR, "performance_proposal_only.csv"), performance_df)

# Compute average goal accuracy per condition
gdf = groupby(df,
    [:condition,
     :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
     :proposal_type, :n_add_particles]
)
performance_per_cond_df = combine(gdf,
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_step" => mean => "runtime_per_step",
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs_std" => mean => "true_goal_probs_std",
    ["true_goal_probs_std", "n_trials"] => ((s, n) -> sqrt(sum(s .^ 2 ./ n)) / length(s)) => "true_goal_probs_sem"
)
performance_df.condition .= "all"
append!(performance_per_cond_df, performance_df)
sort!(performance_per_cond_df,
    [:condition,
     :ngram_vocab, :ngram_multiplier, :ngram_temperature, :ngram_epsilon,
     :proposal_type, :n_add_particles]
)
CSV.write(joinpath(RESULTS_DIR, "performance_proposal_only_per_cond.csv"), performance_per_cond_df)

## Correlation analysis ##

COMPUTE_SE = true

mean_human_df = CSV.read(
    joinpath(HUMAN_RESULTS_DIR, "mean_human_data.csv"), DataFrame
)
sort!(mean_human_df, [:plan_id, :timestep])
mean_human_df.method .= "_human"
mean_human_probs = mean_human_df[:, r"goal_probs_\d+"] |> Matrix

df_path = joinpath(HUMAN_RESULTS_DIR, "human_data.csv")
human_df = CSV.read(df_path, DataFrame)
participant_ids = unique(human_df.participant_code)

"Bootstrap sampling of mean human goal probabilities."
function sample_human_probs(
    human_df, n::Int,
    ids = participant_ids, count = size(mean_human_df, 1)
)
    sampled_mean_probs = Vector{Matrix{Float64}}(undef, n)
    start_col = findfirst(==("goal_probs_1"), names(human_df))
    stop_col = findlast(==("goal_probs_1000"), names(human_df))
    for i in 1:n
        sampled_ids = sample(ids, length(ids), replace=true)
        tmp_df = filter(row -> row.participant_code in sampled_ids, human_df)
        sort!(tmp_df, [:plan_id, :timestep])
        tmp_gdf = DataFrames.groupby(tmp_df, [:plan_id, :timestep])
        if length(tmp_gdf) < count
            continue
        end
        mean_probs = zeros(stop_col-start_col+1, size(mean_human_df, 1))
        for (j, group) in enumerate(tmp_gdf)
            probs = group[:, start_col:stop_col]
            probs = Matrix{Float64}(probs)
            mean_probs[:, j] = mean(probs, dims=1)
        end
        sampled_mean_probs[i] = mean_probs
    end
    return sampled_mean_probs
end

if COMPUTE_SE # This may take a while
    sampled_human_probs = sample_human_probs(human_df, 1000)
end
orig_sampled_human_probs = copy(sampled_human_probs)
sampled_human_probs = sampled_human_probs[1:100]

# Load enumerative results
enumerative_df = CSV.read(
    joinpath(MODEL_RESULTS_DIR, "enumerative.csv"), DataFrame
)
filter!(r -> r.is_judgment, enumerative_df)
sort!(enumerative_df,
    [:goal_prior_type, :ngram_multiplier, :ngram_temperature,
     :search_method, :max_nodes, :replan_period, :act_temperature,
     :plan_id, :timestep]
)

# Compute human similarity measures for all configurations
corr_enumerative_df = DataFrame(
    "goal_prior_type" => String[],
    "ngram_multiplier" => Int[],
    "ngram_temperature" => Float64[],
    "search_method" => String[],
    "max_nodes" => Int[],
    "replan_period" => Int[],
    "act_temperature" => Float64[],
    "goal_cor" => Float64[],
    "goal_overlap" => Float64[],
    "goal_tv" => Float64[],
    "goal_iou" => Float64[],
    "goal_cor_se" => Float64[],
    "goal_overlap_se" => Float64[],
    "goal_tv_se" => Float64[],
    "goal_iou_se" => Float64[]
)
gdf = groupby(enumerative_df,
    ["goal_prior_type", "ngram_multiplier", "ngram_temperature", 
     "search_method", "max_nodes", "replan_period", "act_temperature"]
)
COMPUTE_SE = true
for (key, group) in pairs(gdf)
    n_goals = group.n_goals
    goal_probs = group[:, r"^goal_probs_\d+$"] |> Matrix
    row = Dict(pairs(key))
    row[:goal_cor] = sim_with(cor, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] = sim_with(overlap, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] /= size(mean_human_probs, 1)
    row[:goal_tv] = sim_with(total_variation, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_tv] /= size(mean_human_probs, 1)
    row[:goal_iou] = sim_with(iou, mean_human_probs, per_row=false)(n_goals, goal_probs)
    if COMPUTE_SE
        row[:goal_cor_se] = sim_se_with(cor, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] = sim_se_with(overlap, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] /= size(mean_human_probs, 1)
        row[:goal_tv_se] = sim_se_with(total_variation, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_tv_se] /= size(mean_human_probs, 1)
        row[:goal_iou_se] = sim_se_with(iou, sampled_human_probs, per_row=false)(n_goals, goal_probs)
    end
    push!(corr_enumerative_df, row, cols=:union)
end
CSV.write(joinpath(RESULTS_DIR, "corr_enumerative.csv"), corr_enumerative_df)

judgment_id_df = combine(gdf, eachindex => "judgment_id")
enumerative_df.judgment_id = judgment_id_df.judgment_id
corr_enumerative_per_cond_df = DataFrame(
    "condition" => String[],
    "goal_prior_type" => String[],
    "ngram_multiplier" => Int[],
    "ngram_temperature" => Float64[],
    "search_method" => String[],
    "max_nodes" => Int[],
    "replan_period" => Int[],
    "act_temperature" => Float64[],
    "goal_cor" => Float64[],
    "goal_overlap" => Float64[],
    "goal_tv" => Float64[],
    "goal_iou" => Float64[],
    "goal_cor_se" => Float64[],
    "goal_overlap_se" => Float64[],
    "goal_tv_se" => Float64[],
    "goal_iou_se" => Float64[]
)
gdf = groupby(enumerative_df,
    ["condition", "goal_prior_type", "ngram_multiplier", "ngram_temperature",
     "search_method", "max_nodes", "replan_period", "act_temperature"]
)
for (key, group) in pairs(gdf)
    m_probs = mean_human_probs[group.judgment_id, :]
    n_goals = group.n_goals
    goal_probs = group[:, r"^goal_probs_\d+$"] |> Matrix
    row = Dict(pairs(key))
    row[:goal_cor] = sim_with(cor, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] = sim_with(overlap, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] /= size(m_probs, 1)
    row[:goal_tv] = sim_with(total_variation, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_tv] /= size(m_probs, 1)
    row[:goal_iou] = sim_with(iou, m_probs, per_row=false)(n_goals, goal_probs)
    if COMPUTE_SE
        sampled_m_probs = [probs[:, group.judgment_id] for probs in sampled_human_probs]
        row[:goal_cor_se] = sim_se_with(cor, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] = sim_se_with(overlap, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] /= size(m_probs, 1)
        row[:goal_tv_se] = sim_se_with(total_variation, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_tv_se] /= size(m_probs, 1)
        row[:goal_iou_se] = sim_se_with(iou, sampled_m_probs, per_row=false)(n_goals, goal_probs)
    end
    push!(corr_enumerative_per_cond_df, row, cols=:union)
end
CSV.write(joinpath(RESULTS_DIR, "corr_enumerative_per_cond.csv"), corr_enumerative_per_cond_df)

# Load open ended results
open_ended_df = CSV.read(
    joinpath(MODEL_RESULTS_DIR, "open_ended_mean.csv"), DataFrame
)
filter!(open_ended_df) do r
    r.is_judgment
end

# Compute human similarity measures for all configurations
corr_open_ended_df = DataFrame(
    "goal_prior_type" => String[],
    "ngram_vocab" => String[],
    "ngram_multiplier" => Int[],
    "ngram_temperature" => Float64[],
    "ngram_epsilon" => Float64[],
    "search_method" => String[],
    # "max_nodes" => Int[],
    # "replan_period" => Int[],
    # "act_temperature" => Float64[],
    "proposal_type" => String[],
    "n_add_particles" => Int[],
    "goal_cor" => Float64[],
    "goal_overlap" => Float64[],
    "goal_tv" => Float64[],
    "goal_iou" => Float64[],
    "goal_cor_se" => Float64[],
    "goal_overlap_se" => Float64[],
    "goal_tv_se" => Float64[],
    "goal_iou_se" => Float64[]
)
gdf = groupby(open_ended_df,
    ["goal_prior_type",
     "ngram_vocab", "ngram_multiplier", "ngram_temperature", "ngram_epsilon",
     "search_method", # "max_nodes", "replan_period", "act_temperature",
     "proposal_type", "n_add_particles"]
)
for (key, group) in pairs(gdf)
    n_goals = group.n_goals
    goal_probs = group[:, r"^goal_probs_\d+$"] |> Matrix
    row = Dict(pairs(key))
    row[:goal_cor] = sim_with(cor, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] = sim_with(overlap, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] /= size(mean_human_probs, 1)
    row[:goal_tv] = sim_with(total_variation, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_tv] /= size(mean_human_probs, 1)
    row[:goal_iou] = sim_with(iou, mean_human_probs, per_row=false)(n_goals, goal_probs)
    if COMPUTE_SE
        row[:goal_cor_se] = sim_se_with(cor, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] = sim_se_with(overlap, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] /= size(mean_human_probs, 1)
        row[:goal_tv_se] = sim_se_with(total_variation, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_tv_se] /= size(mean_human_probs, 1)
        row[:goal_iou_se] = sim_se_with(iou, sampled_human_probs, per_row=false)(n_goals, goal_probs)
    end
    push!(corr_open_ended_df, row, cols=:union)
end
CSV.write(joinpath(RESULTS_DIR, "corr_open_ended.csv"), corr_open_ended_df)

judgment_id_df = combine(gdf, eachindex => "judgment_id")
open_ended_df.judgment_id = judgment_id_df.judgment_id
corr_open_ended_per_cond_df = DataFrame(
    "condition" => String[],
    "goal_prior_type" => String[],
    "ngram_vocab" => String[],
    "ngram_multiplier" => Int[],
    "ngram_temperature" => Float64[],
    "ngram_epsilon" => Float64[],
    "search_method" => String[],
    # "max_nodes" => Int[],
    # "replan_period" => Int[],
    # "act_temperature" => Float64[],
    "proposal_type" => String[],
    "n_add_particles" => Int[],
    "goal_cor" => Float64[],
    "goal_overlap" => Float64[],
    "goal_tv" => Float64[],
    "goal_iou" => Float64[],
    "goal_cor_se" => Float64[],
    "goal_overlap_se" => Float64[],
    "goal_tv_se" => Float64[],
    "goal_iou_se" => Float64[]
)
gdf = groupby(open_ended_df,
    ["condition", "goal_prior_type",
     "ngram_vocab", "ngram_multiplier", "ngram_temperature", "ngram_epsilon",
     "search_method", # "max_nodes", "replan_period", "act_temperature",
     "proposal_type", "n_add_particles"]
)
for (key, group) in pairs(gdf)
    m_probs = mean_human_probs[group.judgment_id, :]
    n_goals = group.n_goals
    goal_probs = group[:, r"^goal_probs_\d+$"] |> Matrix
    row = Dict(pairs(key))
    row[:goal_cor] = sim_with(cor, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] = sim_with(overlap, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] /= size(m_probs, 1)
    row[:goal_tv] = sim_with(total_variation, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_tv] /= size(m_probs, 1)
    row[:goal_iou] = sim_with(iou, m_probs, per_row=false)(n_goals, goal_probs)
    if COMPUTE_SE
        sampled_m_probs = [probs[:, group.judgment_id] for probs in sampled_human_probs]
        row[:goal_cor_se] = sim_se_with(cor, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] = sim_se_with(overlap, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] /= size(m_probs, 1)
        row[:goal_tv_se] = sim_se_with(total_variation, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_tv_se] /= size(m_probs, 1)
        row[:goal_iou_se] = sim_se_with(iou, sampled_m_probs, per_row=false)(n_goals, goal_probs)
    end
    push!(corr_open_ended_per_cond_df, row, cols=:union)
end
CSV.write(joinpath(RESULTS_DIR, "corr_open_ended_per_cond.csv"), corr_open_ended_per_cond_df)

# Load proposal only results
proposal_only_df = CSV.read(
    joinpath(MODEL_RESULTS_DIR, "proposal_only_mean.csv"), DataFrame
)
filter!(proposal_only_df) do r
    r.is_judgment
end

# Compute human similarity measures for all configurations
corr_proposal_only_df = DataFrame(
    "ngram_vocab" => String[],
    "ngram_multiplier" => Int[],
    "ngram_temperature" => Float64[],
    "ngram_epsilon" => Float64[],
    "proposal_type" => String[],
    "n_add_particles" => Int[],
    "goal_cor" => Float64[],
    "goal_overlap" => Float64[],
    "goal_tv" => Float64[],
    "goal_iou" => Float64[],
    "goal_cor_se" => Float64[],
    "goal_overlap_se" => Float64[],
    "goal_tv_se" => Float64[],
    "goal_iou_se" => Float64[]
)
gdf = groupby(proposal_only_df,
    ["ngram_vocab", "ngram_multiplier", "ngram_temperature", "ngram_epsilon",
     "proposal_type", "n_add_particles"]
)
for (key, group) in pairs(gdf)
    n_goals = group.n_goals
    goal_probs = group[:, r"^goal_probs_\d+$"] |> Matrix
    row = Dict(pairs(key))
    row[:goal_cor] = sim_with(cor, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] = sim_with(overlap, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] /= size(mean_human_probs, 1)
    row[:goal_tv] = sim_with(total_variation, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_tv] /= size(mean_human_probs, 1)
    row[:goal_iou] = sim_with(iou, mean_human_probs, per_row=false)(n_goals, goal_probs)
    if COMPUTE_SE
        row[:goal_cor_se] = sim_se_with(cor, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] = sim_se_with(overlap, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] /= size(mean_human_probs, 1)
        row[:goal_tv_se] = sim_se_with(total_variation, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_tv_se] /= size(mean_human_probs, 1)
        row[:goal_iou_se] = sim_se_with(iou, sampled_human_probs, per_row=false)(n_goals, goal_probs)
    end
    push!(corr_proposal_only_df, row, cols=:union)
end
CSV.write(joinpath(RESULTS_DIR, "corr_proposal_only.csv"), corr_proposal_only_df)

judgment_id_df = combine(gdf, eachindex => "judgment_id")
proposal_only_df.judgment_id = judgment_id_df.judgment_id
corr_proposal_only_per_cond_df = DataFrame(
    "condition" => String[],
    "ngram_vocab" => String[],
    "ngram_multiplier" => Int[],
    "ngram_temperature" => Float64[],
    "ngram_epsilon" => Float64[],
    "proposal_type" => String[],
    "n_add_particles" => Int[],
    "goal_cor" => Float64[],
    "goal_overlap" => Float64[],
    "goal_tv" => Float64[],
    "goal_iou" => Float64[],
    "goal_cor_se" => Float64[],
    "goal_overlap_se" => Float64[],
    "goal_tv_se" => Float64[],
    "goal_iou_se" => Float64[]
)
gdf = groupby(proposal_only_df,
    ["condition", 
     "ngram_vocab", "ngram_multiplier", "ngram_temperature", "ngram_epsilon",
     "proposal_type", "n_add_particles"]
)
for (key, group) in pairs(gdf)
    m_probs = mean_human_probs[group.judgment_id, :]
    n_goals = group.n_goals
    goal_probs = group[:, r"^goal_probs_\d+$"] |> Matrix
    row = Dict(pairs(key))
    row[:goal_cor] = sim_with(cor, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] = sim_with(overlap, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] /= size(m_probs, 1)
    row[:goal_tv] = sim_with(total_variation, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_tv] /= size(m_probs, 1)
    row[:goal_iou] = sim_with(iou, m_probs, per_row=false)(n_goals, goal_probs)
    if COMPUTE_SE
        sampled_m_probs = [probs[:, group.judgment_id] for probs in sampled_human_probs]
        row[:goal_cor_se] = sim_se_with(cor, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] = sim_se_with(overlap, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] /= size(m_probs, 1)
        row[:goal_tv_se] = sim_se_with(total_variation, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_tv_se] /= size(m_probs, 1)
        row[:goal_iou_se] = sim_se_with(iou, sampled_m_probs, per_row=false)(n_goals, goal_probs)
    end
    push!(corr_proposal_only_per_cond_df, row, cols=:union)
end
CSV.write(joinpath(RESULTS_DIR, "corr_proposal_only_per_cond.csv"), corr_proposal_only_per_cond_df)

## Combined analysis

# Select specific parameters for combined analysis
sel_enumerative_df = filter(enumerative_df) do r
    r.search_method == "bfs" && r.max_nodes == 100 && r.replan_period == 2 && 
    r.goal_prior_type == "categorical" && r.ngram_temperature == 4.0 &&
    r.act_temperature == 1.0
end
sel_open_ended_df = filter(open_ended_df) do r
    r.search_method == "bfs" && r.max_nodes == 100 && r.replan_period == 2 && 
    r.goal_prior_type == "categorical" && r.act_temperature == 1.0 &&
    r.ngram_temperature == 4.0 && r.ngram_epsilon == 0.05 &&
    r.proposal_type == "chained"
end
sel_proposal_only_df = filter(proposal_only_df) do r
    r.ngram_temperature == 4.0 && r.ngram_epsilon == 0.05 &&
    r.proposal_type == "chained"
end

# Combine dataframes
combined_model_df =
    vcat(sel_enumerative_df, sel_open_ended_df, sel_proposal_only_df; cols=:union)
gdf = groupby(combined_model_df, 
    ["method", "goal_prior_type", "act_temperature",
     "search_method", "max_nodes", "replan_period",
     "ngram_temperature", "ngram_epsilon",
     "proposal_type", "n_add_particles"]
)
judgment_id_df = combine(gdf, eachindex => "judgment_id")
combined_model_df.judgment_id = judgment_id_df.judgment_id

# Use full set of bootstrap samples
if COMPUTE_SE
    sampled_human_probs = orig_sampled_human_probs
end

# Compute per-timestep similarity measures
gdf = groupby(combined_model_df, ["method", "n_add_particles"])
corr_per_step_df = combine(gdf,
    "plan_id" => identity => "plan_id",
    "condition" => identity => "condition",
    "cond_id" => identity => "cond_id",
    "timestep" => identity => "timestep",
    "action" => identity => "action",
    ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(cor, mean_human_probs) => "goal_cor",
    ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(overlap, mean_human_probs) => "goal_overlap",
    ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(total_variation, mean_human_probs) => "goal_tv",
    ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_with(iou, mean_human_probs) => "goal_iou",
    ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_se_with(overlap, sampled_human_probs) => "goal_overlap_se",
    ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_se_with(total_variation, sampled_human_probs) => "goal_tv_se",
    ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_se_with(cor, sampled_human_probs) => "goal_cor_se",
    ["n_goals"; ["goal_probs_$i" for i in 1:1000]] => sim_se_with(iou, sampled_human_probs) => "goal_iou_se"
)
CSV.write(joinpath(RESULTS_DIR, "corr_per_step.csv"), corr_per_step_df)

# Compute per-method similarity measures
corr_per_method_df = DataFrame(
    "method" => String[],
    "n_add_particles" => Int[],
    "goal_cor" => Float64[],
    "goal_overlap" => Float64[],
    "goal_tv" => Float64[],
    "goal_iou" => Float64[],
    "goal_cor_se" => Float64[],
    "goal_overlap_se" => Float64[],
    "goal_tv_se" => Float64[],
    "goal_iou_se" => Float64[]
)
gdf = groupby(combined_model_df, ["method", "n_add_particles"])
for (key, group) in pairs(gdf)
    n_goals = group.n_goals
    goal_probs = group[:, r"^goal_probs_\d+$"] |> Matrix
    row = Dict{Symbol, Any}(pairs(key))
    row[:goal_cor] = sim_with(cor, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] = sim_with(overlap, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] /= size(mean_human_probs, 1)
    row[:goal_tv] = sim_with(total_variation, mean_human_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_tv] /= size(mean_human_probs, 1)
    row[:goal_iou] = sim_with(iou, mean_human_probs, per_row=false)(n_goals, goal_probs)
    if COMPUTE_SE
        row[:goal_cor_se] = sim_se_with(cor, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] = sim_se_with(overlap, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] /= size(mean_human_probs, 1)
        row[:goal_tv_se] = sim_se_with(total_variation, sampled_human_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_tv_se] /= size(mean_human_probs, 1)
        row[:goal_iou_se] = sim_se_with(iou, sampled_human_probs, per_row=false)(n_goals, goal_probs)
    end
    push!(corr_per_method_df, row, cols=:union)
end
CSV.write(joinpath(RESULTS_DIR, "corr_per_method.csv"), corr_per_method_df)

# Compute per-method and condition similarity measures
corr_per_method_and_cond_df = DataFrame(
    "condition" => String[],
    "method" => String[],
    "n_add_particles" => Int[],
    "goal_cor" => Float64[],
    "goal_overlap" => Float64[],
    "goal_tv" => Float64[],
    "goal_iou" => Float64[],
    "goal_cor_se" => Float64[],
    "goal_overlap_se" => Float64[],
    "goal_tv_se" => Float64[],
    "goal_iou_se" => Float64[]
)
gdf = groupby(combined_model_df, ["method", "n_add_particles", "condition"])
for (key, group) in pairs(gdf)
    m_probs = mean_human_probs[group.judgment_id, :]
    n_goals = group.n_goals
    goal_probs = group[:, r"^goal_probs_\d+$"] |> Matrix
    row = Dict{Symbol, Any}(pairs(key))
    row[:goal_cor] = sim_with(cor, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] = sim_with(overlap, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_overlap] /= size(m_probs, 1)
    row[:goal_tv] = sim_with(total_variation, m_probs, per_row=false)(n_goals, goal_probs)
    row[:goal_tv] /= size(m_probs, 1)
    row[:goal_iou] = sim_with(iou, m_probs, per_row=false)(n_goals, goal_probs)
    if COMPUTE_SE
        sampled_m_probs = [probs[:, group.judgment_id] for probs in sampled_human_probs]
        row[:goal_cor_se] = sim_se_with(cor, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] = sim_se_with(overlap, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_overlap_se] /= size(m_probs, 1)
        row[:goal_tv_se] = sim_se_with(total_variation, sampled_m_probs, per_row=false)(n_goals, goal_probs)
        row[:goal_tv_se] /= size(m_probs, 1)
        row[:goal_iou_se] = sim_se_with(iou, sampled_m_probs, per_row=false)(n_goals, goal_probs)
    end
    push!(corr_per_method_and_cond_df, row, cols=:union)
end
corr_per_method_df.condition .= "all"
append!(corr_per_method_and_cond_df, corr_per_method_df)
sort!(corr_per_method_and_cond_df, [:condition, :method, :n_add_particles])
CSV.write(joinpath(RESULTS_DIR, "corr_per_method_and_cond.csv"), corr_per_method_and_cond_df)

# Compute average goal accuracy and runtime per method
mean_human_df.method .= "_human"
combined_df = vcat(combined_model_df, mean_human_df, cols=:union)
replace!(combined_df.n_trials, missing => 1)
replace!(combined_df.true_goal_probs_std, missing => 0.0)
gdf = groupby(combined_df, ["method", "n_add_particles"])
performance_df = combine(gdf,
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_step" => mean => "runtime_per_step",
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs_std" => mean => "true_goal_probs_std",
    ["true_goal_probs_std", "n_trials"] => ((s, n) -> sqrt(sum(s .^ 2 ./ n)) / length(s)) => "true_goal_probs_sem"    
)

# Compute log marginal likelihood of dataset for each configuration
gdf = groupby(combined_df, ["condition", "method", "n_add_particles", "plan_id"])
lml_df = combine(gdf, "lml_est" => (x -> last(x)) => "lml_est")
gdf = groupby(lml_df, ["method", "n_add_particles"])
lml_per_method_df = combine(gdf, "lml_est" => sum => "lml_est")
performance_df.lml_est = lml_per_method_df.lml_est

CSV.write(joinpath(RESULTS_DIR, "performance_per_method.csv"), performance_df)

# Compute average goal accuracy and runtime per method and condition
gdf = groupby(combined_df, ["condition", "method", "n_add_particles"])
performance_per_cond_df = combine(gdf,
    "runtime_per_act" => mean => "runtime_per_act",
    "runtime_per_step" => mean => "runtime_per_step",
    "true_goal_probs" => mean => "true_goal_probs",
    "true_goal_probs_std" => mean => "true_goal_probs_std",
    ["true_goal_probs_std", "n_trials"] => ((s, n) -> sqrt(sum(s .^ 2 ./ n)) / length(s)) => "true_goal_probs_sem"
)

# Compute log marginal likelihood for each condition
gdf = groupby(lml_df, ["condition", "method", "n_add_particles"])
lml_per_cond_df = combine(gdf, "lml_est" => sum => "lml_est")
performance_per_cond_df.lml_est = lml_per_cond_df.lml_est

# Append aggregate accuracy as additional condition
performance_df.condition .= "all"
append!(performance_per_cond_df, performance_df)
sort!(performance_per_cond_df, [:condition, :method, :n_add_particles])
CSV.write(joinpath(RESULTS_DIR, "performance_per_method_and_cond.csv"), performance_per_cond_df)
