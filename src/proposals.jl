using Gen, GenParticleFilters

using GenParticleFilters: softmax

"""
    any_tower_proposal(domain, state, actions, [ngram_dist, goal_addr])

A goal proposal that preferentially samples words that complete some tower of
blocks in `state`, biased towards those towers that might form a word.
The `state` follows the most recent action, and `actions` is the action
history so far.

First, we compute the log-likelihood per character of each (partial) tower
under the n-gram prior, along with the likelihood of a random block.

We then normalize these likelihoods, and select a random tower to complete 
according the normalized weights. If we select the entry for the random block,
then we sample from the n-gram goal prior. Otherwise, we sample from the
n-gram distribution conditioned on the characters in the selected tower.

If a block is currently being held, we assume it will either be stacked 
on one of the towers, or put down on the table.
"""
@gen function any_tower_proposal(
    domain::Domain, state::State, actions::AbstractVector{Term},
    ngram_dist = nothing, goal_addr = :init => :agent => :goal => :goal
)
    if isnothing(ngram_dist)
        ngram_dist = construct_ngram_dist(domain, state)
    end
    # Extract all existing block towers
    tower_blocks = extract_all_towers(state)
    held_block = get_held_block(state)
    if !isnothing(held_block)
        for blocks in tower_blocks
            pushfirst!(blocks, held_block)
        end
        push!(tower_blocks, [held_block])
    end
    towers = [join(string.(bs)) for bs in tower_blocks]
    # Compute log-likelihood per block of partial towers under n-gram prior
    tower_logpdfs = [logpdf(ngram_dist, t, "", add_eow=false) / length(t)
                     for t in towers]
    # Compute likelihood of random block
    n_blocks = length(PDDL.get_objects(state, :block))
    baseline_logpdf = log(1/n_blocks)
    # Select a random tower to complete, weighted by likelihood
    tower_probs = softmax([tower_logpdfs; baseline_logpdf])
    tower_idx = categorical(tower_probs)
    if tower_idx <= length(towers)
        goal = {goal_addr} ~ ngram_dist(towers[tower_idx])
    else
        goal = {goal_addr} ~ ngram_dist("")
    end
    return goal
end

"""
    last_tower_proposal(domain, state, actions, [ngram_dist, goal_addr])

A goal proposal that preferentially samples words that complete the
most recently stacked tower of blocks, where `state` follows the most recent
action, and `actions` is the action history so far.

If the most recent action either stacks or puts down a block, then we compute
the probabality ``p`` of the most recently stacked tower under an n-gram prior.
We also compute ``q``, the baseline probability of a tower of the same height
under a uniform block-stacking prior.

We then decide with probability ``p / (p + q)`` to sample from the n-gram
distribution conditioned on the characters in the most recently stacked tower.
Otherwise, we fallback to `any_tower_proposal`.
"""
@gen function last_tower_proposal(
    domain::Domain, state::State, actions::AbstractVector{Term},
    ngram_dist = nothing, goal_addr = :init => :agent => :goal => :goal
)
    if isnothing(ngram_dist)
        ngram_dist = construct_ngram_dist(domain, state)
    end
    # Fallback to `any_tower_proposal` if last action is not a stacking action
    act = !isempty(actions) ? actions[end] : nothing
    if isnothing(act) || (act.name != Symbol("stack") && act.name != Symbol("put-down"))
        goal = {*} ~ any_tower_proposal(domain, state, actions,
                                        ngram_dist, goal_addr)
        return goal
    end
    # Extract most recently stacked tower
    top = act.args[1]
    tower_blocks = extract_tower(state, top, :down)
    tower = join(string.(tower_blocks))
    # Compute log-likelihood of tower under n-gram prior
    tower_logpdf = logpdf(ngram_dist, tower, "", add_eow=false)
    # Compute likelihood of equally tall tower of random blocks
    n_blocks = length(PDDL.get_objects(state, :block))
    baseline_logpdf = log(1/n_blocks) * length(tower)
    # Decide whether to sample from `any_tower_proposal` or tower completion
    p = 1 / (1 + exp(baseline_logpdf - tower_logpdf))
    if rand() < p
        goal = {goal_addr} ~ ngram_dist(tower)
    else
        goal = {*} ~ any_tower_proposal(domain, state, actions,
                                        ngram_dist, goal_addr)
    end
    return goal
end

"""
    next_tower_proposal(domain, state, actions, [ngram_dist, goal_addr])

A goal proposal that preferentially samples words that involve one of the 
letters in the last unstacked tower of blocks, on the hypothesis that one of 
those letters will be the next block of the tower being stacked.

First, we determine the all possible towers that could be stacked 
by using one of the blocks in the last unstacked tower. We then compute the
log-likelihood per character of each (partial) tower under the n-gram prior,
along with the likelihood of a random block.

We then select a random tower to complete according the normalized
average log-likelihoods. If we select the entry for the random block,
then we fallback to `any_tower_proposal`. Otherwise, we sample from the
n-gram distribution conditioned on the characters in the selected tower.

If no tower was unstacked by the last two actions, we fallback to
`any_tower_proposal`.
"""
@gen function next_tower_proposal(
    domain::Domain, state::State, actions::AbstractVector{Term},
    ngram_dist = nothing, goal_addr = :init => :agent => :goal => :goal
)
    if isnothing(ngram_dist)
        ngram_dist = construct_ngram_dist(domain, state)
    end
    # Determine tower that was last unstacked
    last_action_pair = @view actions[max(1, length(actions)-1):end]
    act_idx = findlast(a -> a.name == Symbol("unstack"), last_action_pair)
    if isnothing(act_idx)
        goal = {*} ~ any_tower_proposal(domain, state, actions,
                                        ngram_dist, goal_addr)
        return goal
    end
    act = last_action_pair[act_idx]
    top = act.args[2]
    last_tower_blocks = extract_tower(state, top, :down)
    last_tower = join(string.(last_tower_blocks))
    # Extract all other block towers
    tower_blocks = extract_all_towers(state)
    towers = [join(string.(bs)) for bs in tower_blocks]
    filter!(!=(last_tower), towers)
    # Consider stacking each block in the last tower on the other towers
    new_towers = reduce(vcat, [c * t for c in last_tower, t in towers])
    append!(new_towers, [string(c) for c in last_tower])
    push!(new_towers, last_tower)
    # Compute log-likelihood per block of partial towers under goal prior
    tower_logpdfs = [logpdf(ngram_dist, t, "", add_eow=false) / length(t)
                     for t in new_towers]
    # Compute likelihood of random block
    n_blocks = length(PDDL.get_objects(state, :block))
    baseline_logpdf = log(1/n_blocks)
    # Select a random tower to complete, weighted by likelihood
    tower_probs = softmax([tower_logpdfs; baseline_logpdf])
    tower_idx = categorical(tower_probs)
    if tower_idx <= length(towers)
        goal = {goal_addr} ~ ngram_dist(towers[tower_idx])
    else
        goal = {*} ~ any_tower_proposal(domain, state, actions,
                                        ngram_dist, goal_addr)
    end
    return goal
end

"""
    chained_tower_proposal(domain, state, actions, [ngram_dist, goal_addr])

A goal proposal that combines aspects of `last_tower_proposal`,
`next_tower_proposal`, and `any_tower_proposal` in a chained manner.

First tries to complete the tower that was last stacked, as in
`last_tower_proposal`. If the decision is made not to do this, fallback
to `next_tower_proposal`, which in turn falls back to `any_tower_proposal`.

If no tower was last stacked, we fallback to `any_tower_proposal`.
"""
@gen function chained_tower_proposal(
    domain::Domain, state::State, actions::AbstractVector{Term},
    ngram_dist = nothing, goal_addr = :init => :agent => :goal => :goal
)
    if isnothing(ngram_dist)
        ngram_dist = construct_ngram_dist(domain, state)
    end
    # Fallback to `any_tower_proposal` if last action was not stacking
    act = !isempty(actions) ? actions[end] : nothing
    if isnothing(act) || (act.name != Symbol("stack") && act.name != Symbol("put-down"))
        goal = {*} ~ any_tower_proposal(domain, state, actions,
                                        ngram_dist, goal_addr)
        return goal
    end
    # Extract most recently stacked tower
    top = act.args[1]
    tower_blocks = extract_tower(state, top, :down)
    tower = join(string.(tower_blocks))
    # Compute log-likelihood of tower under n-gram prior
    tower_logpdf = logpdf(ngram_dist, tower, "", add_eow=false)
    # Compute likelihood of equally tall tower of random blocks
    n_blocks = length(PDDL.get_objects(state, :block))
    baseline_logpdf = log(1/n_blocks) * length(tower)
    # Decide whether to sample from `next_tower_proposal` or tower completion
    p = 1 / (1 + exp(baseline_logpdf - tower_logpdf))
    if rand() < p
        goal = {goal_addr} ~ ngram_dist(tower)
    else
        goal = {*} ~ next_tower_proposal(domain, state, actions,
                                         ngram_dist, goal_addr)
    end
    return goal
end
