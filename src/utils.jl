using PDDL

"Converts a word to a list of terms representing a tower of blocks."
function word_to_terms(word::String)
    top = Const(Symbol(word[1]))
    bottom = Const(Symbol(word[end]))
    terms = Term[Compound(:clear, [top]), Compound(:ontable, [bottom])]
    for (c1, c2) in zip(word[1:end-1], word[2:end])
        c1, c2 = Const(Symbol(c1)), Const(Symbol(c2))
        push!(terms, Compound(:on, [c1, c2]))
    end
    return terms
end

"Converts a list of terms representing a tower of blocks to a word."
function terms_to_word(terms::AbstractVector{<:Term})
    relations = Dict{Symbol, Vector{Symbol}}()
    for term in terms
        if term.name == :on
            c1, c2 = term.args
            above = get!(relations, c2.name, Symbol[])
            push!(above, c1.name)
        elseif term.name == :clear
            c1 = term.args[1]
            above = get!(relations, c1.name, Symbol[])
        elseif term.name == :ontable
            c1 = term.args[1]
            above = get!(relations, :table, Symbol[])
            push!(above, c1.name)
        else
            error("Invalid predicate: $term")
        end
    end
    word = ""
    block = :table
    while true
        above = relations[block]
        isempty(above) && break
        length(above) > 1 && error("More than one block above $block.")
        block = first(above)
        word = string(block) * word
    end
    return word
end
terms_to_word(term::Term) = terms_to_word(PDDL.flatten_conjs(term))

"Extract all objects from a list of (goal) terms."
function extract_objects(terms::AbstractVector{<:Term})
    objects = Const[]
    extract_objects!(objects, terms)
    return objects
end

function extract_objects!(objects::Vector{Const}, terms::AbstractVector{<:Term})
    for term in terms
        if PDDL.is_logical_op(term)
            extract_objects!(objects, term.args)
        elseif PDDL.is_global_func(term)
            extract_objects!(objects, term.args)
        else
            append!(objects, term.args)
        end
    end
    return unique!(objects)
end

"Returns the block that is currently held."
function get_held_block(state::State)
    for block in PDDL.get_objects(state, :block)
        if state[pddl"(holding $block)"]
            return block
        end
    end
    return nothing
end

"""
    extract_tower(state::State, init_block::Const, dir::Symbol)

Extracts a tower of blocks, starting from `init_block`, in either
the `:up` or `:down` direction."
"""
function extract_tower(state::State, init_block::Const, dir::Symbol)
    blocks = PDDL.get_objects(state, :block)
    cur_block = init_block
    tower = Const[init_block]
    while !isnothing(cur_block)
        found = false
        for b in blocks
            if (dir == :up && state[pddl"(on $b $cur_block)"] ||
                dir == :down && state[pddl"(on $cur_block $b)"])
                cur_block = b
                if dir == :up
                    pushfirst!(tower, cur_block)
                else
                    push!(tower, cur_block)
                end
                found = true
                break
            end
        end
        if !found
            cur_block = nothing
        end
    end
    return tower
end

"Extract all block towers from the state."
function extract_all_towers(state::State)
    blocks = PDDL.get_objects(state, :block)
    table_blocks = [b for b in blocks if state[pddl"(ontable $b)"]]
    return [extract_tower(state, b, :up) for b in table_blocks]
end
