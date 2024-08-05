using Gen
using DataStructures: DataStructures, Accumulator, OrderedDict
using Random

"Load a word frequency list into a dictionary mapping words to frequency counts."
function load_wordfreq_list(
    path::AbstractString,
    allowed = collect('a':'z')
)
    vocab = Dict{String, Int}()
    for line in eachline(path)
        isempty(line) && continue
        word, count = split(line)
        count = parse(Int, count)
        all(c in allowed for c in word) || continue
        isempty(word) && continue
        vocab[word] = count
    end
    return vocab
end

"Load a word list into a dictionary mapping words to frequency counts."
function load_word_list(
    path::AbstractString,
    allowed = collect('a':'z');
    default_count = 1,
    strip_final_char_flags = true
)
    vocab = Dict{String, Int}()
    for line in eachline(path)
        isempty(line) && continue
        word = strip(line)
        if strip_final_char_flags && !(word[end] in allowed)
            word = word[1:end-1]
        end
        all(c in allowed for c in word) || continue
        isempty(word) && continue
        vocab[word] = default_count
    end
    return vocab
end

"Filter a vocabulary to include only words made from the available characters."
function filter_vocab(
    vocab::Dict{String, T},
    available_chars::Accumulator
) where {T <: Real}
    new_vocab = Dict{String, T}()
    for (word, count) in vocab
        word_chars = DataStructures.counter(word)
        word_chars ⊆ available_chars || continue
        new_vocab[word] = count
    end
    return new_vocab
end

filter_vocab(vocab, available_chars) = 
    filter_vocab(vocab, DataStructures.counter(available_chars))

"Reverse all the words in a vocabulary."
function reverse_vocab(vocab::Dict{String, T}) where {T <: Real}
    new_vocab = Dict{String, T}()
    for (word, count) in vocab
        new_vocab[reverse(word)] = count
    end
    return new_vocab
end

"Scale all the counts in a vocabulary by a constant multiplier."
function multiply_vocab_counts(
    vocab::Dict{String, T}, multiplier::V
) where {T <: Real, V <: Real}
    new_vocab = Dict{String, typejoin(T, V)}()
    for (word, count) in vocab
        new_vocab[word] = count * multiplier
    end
    return new_vocab
end

"Perform temperature scaling on a vocabulary."
function temper_vocab_counts(
    vocab::Dict{String, T}, temperature::Real
) where {T <: Real}
    new_vocab = Dict{String, Float64}()
    for (word, count) in vocab
        new_vocab[word] = count ^ (1/temperature)
    end
    return new_vocab
end

"Convert a vocabulary to a dictionary mapping n-grams to counts."
function vocab_to_ngram_counts(
    vocab::Dict{String, T}, n::Int;
    alphabet = collect('a':'z')
) where {T <: Real}
    ngram_counts = Dict{String, Vector{T}}()
    for (word, count) in vocab
        # Count each n-gram in the word
        for (i, char) in enumerate(word)
            prefix = word[max(1,i-n+1):i-1]
            char_counts = get!(ngram_counts, prefix) do 
                zeros(T, length(alphabet) + 1)
            end
            char_idx = findfirst(==(char), alphabet)
            char_counts[char_idx] += count
        end
        # Count end-of-word characters
        prefix = word[max(1,length(word)-n+2):end]
        char_counts = get!(ngram_counts, prefix) do 
            zeros(T, length(alphabet) + 1)
        end
        char_counts[end] += count
    end
    return ngram_counts
end

"Get the counts for a n-gram prefix, with backoff to shorter prefixes."
function get_counts_with_backoff(
    ngram_counts::Dict{String, <:AbstractVector{T}},
    prefix::String, n_chars::Int
) where {T <: Real}
    return get(ngram_counts, prefix) do
        if isempty(prefix)
            zeros(T, n_chars)
        else
            get_counts_with_backoff(ngram_counts, prefix[2:end], n_chars)
        end
    end
end

"""
    NgramWordDist(
        vocab::Dict{String, <:Real}, n::Int;
        alphabet = join('a':'z'),
        eow_char = ' ',
        gamma = 1.0,
        epsilon = 0.0,
        reversed = false,
        temperature = nothing,
        multiplier = nothing
    )

A character-level n-gram model over words. Once constructed, an `ngram_dist`
can be used to sample words that are completions of a given `prefix`:

    word ~ ngram_dist(prefix)

# Arguments

- `vocab`: A dictionary mapping words to counts.
- `n`: The order of the n-gram model.
- `alphabet`: The set of characters to use in the model.
- `eow_char`: The character to use to mark the end of a word.
- `gamma`: A pseudocount to add to each n-gram count.
- `epsilon`: The word continuation probability is scaled by `(1 - epsilon)`. 
- `reversed`: Whether generate words backwards, starting from a postfix.
- `temperature`: Rescales vocabulary counts by temperature if provided.
- `multiplier`: Multiplies vocabulary counts by constant after tempering.

"""
struct NgramWordDist{T <: Real} <: Gen.Distribution{String}
    ngram_counts::Dict{String, Vector{T}}
    n::Int
    alphabet::String
    eow_char::Char
    gamma::Float64
    epsilon::Float64
    reversed::Bool
end

function NgramWordDist(
    vocab::Dict{String, T}, n::Int;
    alphabet = join('a':'z'),
    eow_char = ' ',
    gamma = 1.0,
    epsilon = 0.0,
    reversed = false,
    multiplier::Union{Nothing, Real} = nothing,
    temperature::Union{Nothing, Real} = nothing
) where {T <: Real}
    vocab = reversed ? reverse_vocab(vocab) : vocab
    vocab = isnothing(temperature) ?
        vocab : temper_vocab_counts(vocab, temperature)
    vocab = isnothing(multiplier) ?
        vocab : multiply_vocab_counts(vocab, multiplier)
    ngram_counts = vocab_to_ngram_counts(vocab, n; alphabet)
    C = isnothing(temperature) ? T : Float64
    return NgramWordDist{C}(
        ngram_counts, n, alphabet, eow_char, gamma, epsilon, reversed
    )
end

(dist::NgramWordDist)(prefix::String) = Gen.random(dist, prefix)

function Gen.random(dist::NgramWordDist, prefix::String)
    word = dist.reversed ? reverse(prefix) : prefix
    char_probs = zeros(Float64, length(dist.alphabet) + 1)
    while true
        cur_prefix = word[max(1,length(word)-dist.n+2):end]
        char_counts = get_counts_with_backoff(dist.ngram_counts, cur_prefix, 
                                              length(dist.alphabet) + 1)
        char_probs .= (char_counts .+ dist.gamma)
        isempty(word) && (char_probs[end] = 0.0)
        char_probs ./= sum(char_probs)
        if dist.epsilon > 0 && !isempty(word)
            char_probs[1:end-1] .*= (1 - dist.epsilon)
            char_probs[end] = 1.0 - sum(char_probs[1:end-1])
        end
        idx = categorical(char_probs)
        idx == length(char_counts) && break
        word *= dist.alphabet[idx]
    end
    return dist.reversed ? reverse(word) : word
end

function Gen.logpdf(dist::NgramWordDist, word::String, prefix::String;
                    add_eow::Bool = true)
    logprobs = 0.0
    prefix = dist.reversed ? reverse(prefix) : prefix
    word = dist.reversed ? reverse(word) : word
    word = add_eow ? word * dist.eow_char : word
    char_probs = zeros(Float64, length(dist.alphabet) + 1)
    for (i, char) in enumerate(word)
        if i <= length(prefix)
            char == prefix[i] || return -Inf
            char in dist.alphabet || return -Inf
            continue
        end
        cur_prefix = word[max(1,i-dist.n+1):i-1]
        char_counts = get_counts_with_backoff(dist.ngram_counts, cur_prefix, 
                                              length(dist.alphabet) + 1)
        idx = char == dist.eow_char ?
            length(char_counts) : findfirst(==(char), dist.alphabet)
        if isnothing(idx)
            return -Inf
        end
        char_probs .= (char_counts .+ dist.gamma)
        (i == 1) && (char_probs[end] = 0.0)
        char_probs ./= sum(char_probs)
        if dist.epsilon > 0 && i > 1
            char_probs[1:end-1] .*= (1 - dist.epsilon)
            char_probs[end] = 1.0 - sum(char_probs[1:end-1])
        end
        logprobs += log(char_probs[idx])
    end
    return logprobs
end

Gen.logpdf_grad(dist::NgramWordDist, word::String, prefix::String) = 
    (nothing, nothing)

Gen.has_output_grad(dist::NgramWordDist) = false
Gen.has_argument_grads(dist::NgramWordDist) = (false,)
Gen.is_discrete(dist::NgramWordDist) = true

"""
    ConstrainedNgramWordDist(
        vocab::Dict{String, <:Real}, n::Int, chars;
        eow_char = ' ',
        gamma = 1.0,
        epsilon = 0.0,
        reversed = false,
        temperature = nothing,
        multiplier = nothing
    )

A character-level n-gram model over words that can be constructed from a 
bag of `chars`. Once constructed, an `ngram_dist` can be used to sample words
that are completions of a given `prefix`:

    word ~ ngram_dist(prefix)

# Arguments

- `vocab`: A dictionary mapping words to counts.
- `chars`: The (multi)set of characters that can be used to construct words.
- `n`: The order of the n-gram model.
- `alphabet`: The set of characters to use in the model.
- `eow_char`: The character to use to mark the end of a word.
- `min_chars`: The minimum number of characters in a word.
- `max_chars`: The maximum number of characters in a word.
- `gamma`: A pseudocount to add to each n-gram count.
- `epsilon`: The word continuation probability is scaled by `(1 - epsilon)`.
- `reversed`: Whether generate words backwards, starting from a postfix.
- `temperature`: Rescales vocabulary counts by temperature if provided.
- `multiplier`: Multiplies vocabulary counts by constant after tempering.

"""
struct ConstrainedNgramWordDist{T <: Real} <: Gen.Distribution{String}
    ngram_counts::Dict{String, Vector{T}}
    n::Int
    chars::Vector{Char}
    alphabet::String
    eow_char::Char
    min_chars::Int
    max_chars::Int
    gamma::Float64
    epsilon::Float64
    reversed::Bool
end

function ConstrainedNgramWordDist(
    vocab::Dict{String, T}, n::Int, chars;
    alphabet = join(unique(chars)),
    eow_char = ' ',
    min_chars = 1,
    max_chars = length(chars),
    gamma = 1.0,
    epsilon = 0.0,
    reversed = false,
    temperature::Union{Nothing, Float64} = nothing,
    multiplier::Union{Nothing, Real} = nothing
) where {T <: Real}
    vocab = filter_vocab(vocab, chars)
    vocab = reversed ? reverse_vocab(vocab) : vocab
    vocab = isnothing(temperature) ?
        vocab : temper_vocab_counts(vocab, temperature)
    vocab = isnothing(multiplier) ?
        vocab : multiply_vocab_counts(vocab, multiplier)
    ngram_counts = vocab_to_ngram_counts(vocab, n; alphabet)
    chars = collect(Char, chars)
    C = isnothing(temperature) ? T : Float64
    return ConstrainedNgramWordDist{C}(
        ngram_counts, n, chars, alphabet,
        eow_char, min_chars, max_chars,
        gamma, epsilon, reversed
    )
end

(dist::ConstrainedNgramWordDist)(prefix::String) = Gen.random(dist, prefix)

function Gen.random(dist::ConstrainedNgramWordDist, prefix::String)
    word = dist.reversed ? reverse(prefix) : prefix
    char_probs = zeros(Float64, length(dist.alphabet) + 1)
    chars_left = DataStructures.counter(dist.chars)
    for char in word
        chars_left[char] -= 1
    end
    while length(word) < dist.max_chars
        cur_prefix = word[max(1,length(word)-dist.n+2):end]
        char_counts = get_counts_with_backoff(dist.ngram_counts, cur_prefix, 
                                              length(dist.alphabet) + 1)
        char_probs .= (char_counts .+ dist.gamma)
        for (j, char) in enumerate(dist.alphabet)
            char_probs[j] *= chars_left[char] > 0 ? 1 : 0
        end
        if length(word) < dist.min_chars
            char_probs[end] = 0.0
        end
        char_probs ./= sum(char_probs)
        if dist.epsilon > 0 && length(word) >= dist.min_chars
            char_probs[1:end-1] .*= (1 - dist.epsilon)
            char_probs[end] = 1.0 - sum(char_probs[1:end-1])
        end
        idx = categorical(char_probs)
        idx == length(char_counts) && break
        char = dist.alphabet[idx]
        chars_left[char] -= 1
        word *= dist.alphabet[idx]
    end
    return dist.reversed ? reverse(word) : word
end

function Gen.logpdf(dist::ConstrainedNgramWordDist,
                    word::String, prefix::String;
                    add_eow::Bool = true)
    !(dist.min_chars <= length(word) <= dist.max_chars) && return -Inf
    length(prefix) > dist.max_chars && return -Inf
    logprobs = 0.0
    char_probs = zeros(Float64, length(dist.alphabet) + 1)
    chars_left = DataStructures.counter(dist.chars)
    prefix = dist.reversed ? reverse(prefix) : prefix
    word = dist.reversed ? reverse(word) : word
    word = add_eow ? word * dist.eow_char : word
    for (i, char) in enumerate(word)
        if i <= length(prefix)
            char == dist.eow_char && return -Inf
            char == prefix[i] || return -Inf
            chars_left[char] > 0 || return -Inf
            chars_left[char] -= 1
            continue
        end
        if char != dist.eow_char && chars_left[char] == 0
            return -Inf
        end
        cur_prefix = word[max(1,i-dist.n+1):i-1]
        char_counts = get_counts_with_backoff(dist.ngram_counts, cur_prefix, 
                                              length(dist.alphabet) + 1)
        idx = char == dist.eow_char ?
            length(char_counts) : findfirst(==(char), dist.alphabet)
        if isnothing(idx)
            return -Inf
        end
        char_probs .= (char_counts .+ dist.gamma)
        for (j, char) in enumerate(dist.alphabet)
            char_probs[j] *= chars_left[char] > 0 ? 1 : 0
        end
        if i <= dist.min_chars
            char_probs[end] = 0.0
        end
        char_probs ./= sum(char_probs)
        if dist.epsilon > 0 && i > dist.min_chars
            char_probs[1:end-1] .*= (1 - dist.epsilon)
            char_probs[end] = 1.0 - sum(char_probs[1:end-1])
        end
        logprobs += log(char_probs[idx])
        chars_left[char] -= 1
    end
    return logprobs
end

Gen.logpdf_grad(dist::ConstrainedNgramWordDist, word::String, prefix::String) = 
    (nothing, nothing)

Gen.has_output_grad(dist::ConstrainedNgramWordDist) = false
Gen.has_argument_grads(dist::ConstrainedNgramWordDist) = (false,)
Gen.is_discrete(dist::ConstrainedNgramWordDist) = true

"""
    UniformWordDist(words)

A uniform distribution over a set of words.
"""
struct UniformWordDist <: Gen.Distribution{String}
    words::Set{String}
end

UniformWordDist(words::AbstractVector{<:AbstractString}) =
    UniformWordDist(convert.(String, words))
UniformWordDist(words::AbstractVector{String}) = 
    UniformWordDist(Set(words))

(dist::UniformWordDist)() = Gen.random(dist)

Gen.random(dist::UniformWordDist) = rand(dist.words)

Gen.logpdf(dist::UniformWordDist, word::String) =
    word in dist.words ? -log(length(dist.words)) : -Inf

Gen.logpdf_grad(dist::UniformWordDist, word::String) = (nothing,)
Gen.has_output_grad(dist::UniformWordDist) = false
Gen.has_argument_grads(dist::UniformWordDist) = ()
Gen.is_discrete(dist::UniformWordDist) = true

"""
    CategoricalWordDist(vocab::AbstractDict)

A categorical distribution over a set of words.
"""
struct CategoricalWordDist <: Gen.Distribution{String}
    vocab::OrderedDict{String, Float64}
end

function CategoricalWordDist(
    vocab::AbstractDict{<:AbstractString, <:Real};
    temperature::Union{Nothing, Float64} = nothing,
    multiplier::Union{Nothing, Real} = nothing
)   
    if !isnothing(temperature)
        vocab = temper_vocab_counts(vocab, temperature)
    end
    if !isnothing(multiplier)
        vocab = multiply_vocab_counts(vocab, multiplier)
    end
    logprobs = log.(values(vocab)) .- log(sum(values(vocab)))
    vocab = OrderedDict{String, Float64}(zip(keys(vocab), logprobs))
    return CategoricalWordDist(vocab)
end

(dist::CategoricalWordDist)() = Gen.random(dist)

function Gen.random(dist::CategoricalWordDist)
    chosen_word, chosen_score = missing, -Inf
    for (word, logprob) in dist.vocab
        score = logprob + randgumbel()
        if score > chosen_score
            chosen_word = word
            chosen_score = score
        end
    end
    return chosen_word
end

Gen.logpdf(dist::CategoricalWordDist, word::String) =
    get(dist.vocab, word, -Inf)

Gen.logpdf_grad(dist::CategoricalWordDist, word::String) = (nothing,)
Gen.has_output_grad(dist::CategoricalWordDist) = false
Gen.has_argument_grads(dist::CategoricalWordDist) = ()
Gen.is_discrete(dist::CategoricalWordDist) = true

"Return sample from the standard Gumbel distribution."
function randgumbel(rng::AbstractRNG=Random.GLOBAL_RNG)
    return -log(-log(rand(rng)))
end
