using SymbolicPlanners

import SymbolicPlanners:
    precompute!, is_precomputed, compute, filter_available, get_goal_terms

mutable struct BlocksworldActionFilter <: Heuristic
    goal_blocks::Vector{Const}
    relevant_blocks::Vector{Const}
    goal_hash::Union{UInt, Nothing}
    BlocksworldActionFilter() = new(Const[], Const[], nothing)
end

function precompute!(h::BlocksworldActionFilter, domain::Domain, state::State)
    empty!(h.goal_blocks)
    empty!(h.relevant_blocks)
    append!(h.relevant_blocks, PDDL.get_objects(state, :block))
    h.goal_hash = nothing
    return h
end

function precompute!(h::BlocksworldActionFilter,
                     domain::Domain, state::State, spec::Specification)
    goal_terms = get_goal_terms(spec)
    goal = PDDL.dequantify(Compound(:and, goal_terms), domain, state)
    goal_terms = PDDL.flatten_conjs(goal)
    h.goal_blocks = extract_objects(goal_terms)
    h.relevant_blocks = extract_relevant_blocks(state, h.goal_blocks)
    h.goal_hash = hash(goal_terms)
    return h
end

is_precomputed(h::BlocksworldActionFilter) = isdefined(h, :goal_hash)

function compute(h::BlocksworldActionFilter,
                 domain::Domain, state::State, spec::Specification)
    return 0
end

function filter_available(h::BlocksworldActionFilter,
                          domain::Domain, state::State, spec::Specification)
    # If necessary, update action filter with new goal
    if isnothing(h.goal_hash) || h.goal_hash != hash(get_goal_terms(spec))
        precompute!(h, domain, state, spec)
    end
    return (act for act in available(domain, state) if 
            act.args[1] in h.relevant_blocks)
end

"Extract all blocks relevant to stacking the goal blocks."
function extract_relevant_blocks(state::State, goal_blocks::Vector{Const})
    relevant_blocks = Const[]
    for block in goal_blocks
        blocks_above = extract_tower(state, block, :up)
        append!(relevant_blocks, blocks_above)
        push!(relevant_blocks, block)
    end
    for block in PDDL.get_objects(state, :block)
        if state[pddl"(holding $block)"]
            push!(relevant_blocks, block)
        end
    end
    return unique!(relevant_blocks)
end
