using PDDL, SymbolicPlanners
using PDDLViz, GLMakie
using JSON3
using FFMPEG: ffprobe

include("src/utils.jl")
include("src/plan_io.jl")

# Construct blocksworld renderer
RENDERER = BlocksworldRenderer(resolution=(800, 800))

"Generates stimulus animation from a initial state and plan."
function generate_stim_anim(
    path::Union{AbstractString, Nothing},
    domain::Domain,
    state::State,
    plan::AbstractVector{<:Term};
    renderer = RENDERER,
    framerate = 25,
    format = "gif",
    loop = -1,
    kwargs...
)
    # Animate plan
    anim = anim_plan(renderer, domain, state, plan;
                     framerate, format, loop, kwargs...)
    # Save animation
    if !isnothing(path)
        save(path, anim)
    end
    return anim
end

function generate_stim_anim(
    path::Union{AbstractString, Nothing},
    domain::Domain,
    problem::Problem,
    plan::AbstractVector{<:Term};
    renderer = RENDERER,
    kwargs...
)
    state = initstate(domain, problem)
    anim = nothing
    # Set block order based on problem object ordering
    location_types = renderer.location_types
    renderer.location_types = Symbol[]
    locations = renderer.locations
    renderer.locations = vcat(locations, PDDL.get_objects(problem))
    try
        # Generate animation
        anim = generate_stim_anim(path, domain, state, plan;
                                  renderer, kwargs...)
    finally
        # Reset block order
        renderer.location_types = location_types
        renderer.locations = locations
    end
    return anim
end

"Create storyboard plot from a stimulus."
function generate_stim_storyboard(
    domain::Domain,
    problem::Problem,
    plan::AbstractVector{<:Term},
    timesteps::AbstractVector{Int};
    subtitles = fill("", length(timesteps)),
    xlabels = fill("", length(timesteps)),
    xlabelsize = 20, subtitlesize = 24, n_rows = 1,
    kwargs...
)
    # Generate animation without smooth transitions
    anim = generate_stim_anim(nothing, domain, problem, plan;
                              transition=PDDLViz.StepTransition(), kwargs...)
    # Create goal inference storyboard
    timesteps = timesteps .+ 1
    storyboard = render_storyboard(
        anim, timesteps;
        subtitles, xlabels, xlabelsize, subtitlesize, n_rows
    )
    return storyboard
end

"Generates animation segments from an initial state, plan, and splitpoints."
function generate_stim_anim_segments(
    basepath::Union{AbstractString, Nothing},
    domain::Domain,
    state::State,
    plan::AbstractVector{<:Term},
    splitpoints::AbstractVector{Int};
    renderer = RENDERER,
    framerate = 25,
    format = "gif",
    loop = -1,
    kwargs...
)
    trajectory = PDDL.simulate(domain, state, plan)
    # Adjust splitpoints to include the start and end of the trajectory
    splitpoints = copy(splitpoints) .+ 1
    if isempty(splitpoints) || last(splitpoints) != length(trajectory)
        push!(splitpoints, length(trajectory))
    end
    pushfirst!(splitpoints, 1)
    # Render initial state
    canvas = render_state(renderer, domain, state)
    if !isnothing(basepath)
        init_anim = PDDLViz.Animation(canvas; format, loop)
        recordframe!(init_anim)
        save("$basepath-0.$format", init_anim)
    end
    # Animate trajectory segments between each splitpoint
    anims = PDDLViz.Animation[]
    for i in 1:length(splitpoints)-1
        a, b = splitpoints[i:i+1]
        anim = anim_trajectory!(canvas, renderer, domain,
                                trajectory[a:b], plan[a:b-1];
                                framerate, format, loop, show=false, kwargs...)
        if !isnothing(basepath)
            save("$basepath-$i.$format", anim)
        end
        push!(anims, anim)
    end
    return anims
end

function generate_stim_anim_segments(
    basepath::Union{AbstractString, Nothing},
    domain::Domain,
    problem::Problem,
    plan::AbstractVector{<:Term},
    splitpoints::AbstractVector{Int};
    renderer = RENDERER,
    kwargs...
)
    state = initstate(domain, problem)
    anims = nothing
    # Set block order based on problem object ordering
    location_types = renderer.location_types
    renderer.location_types = Symbol[]
    locations = renderer.locations
    renderer.locations = vcat(locations, PDDL.get_objects(problem))
    try
        # Generate animation segments
        anims = generate_stim_anim_segments(
            basepath, domain, state, plan, splitpoints; renderer, kwargs...
        )
    finally
        # Reset block order
        renderer.location_types = location_types
        renderer.locations = locations
    end
    return anims
end

"Generate stimuli JSON metadata."
function generate_stim_json(
    name::String,
    problem::Problem,
    plan::AbstractVector{<:Term},
    splitpoints::AbstractVector{Int};
    condition = match(r"\w+-(\w+)-\d+", name).captures[1],
    images_dir = joinpath(@__DIR__, "stimuli", "segments")
)
    goal_terms = PDDL.flatten_conjs(PDDL.get_goal(problem))
    goal_word = terms_to_word(goal_terms)
    n_images = length(splitpoints) + 1
    if isempty(splitpoints) || last(splitpoints) != length(plan)
        n_images += 1
    end
    objects = PDDL.get_objects(problem)
    object_str = join([string(o) for o in objects])
    frame_counts = Int[]
    durations = Float64[]
    for i in 0:n_images-1
        path = joinpath(images_dir, "$name-$i.gif")
        n_frames, duration = count_frames_and_duration(path)
        push!(frame_counts, n_frames)
        push!(durations, duration)
    end
    json = (
        name = name,
        condition = condition,
        goal = goal_word,
        characters = object_str,
        timesteps = splitpoints,
        images = ["$name-$i.gif" for i in 0:n_images-1],
        frame_counts = frame_counts,
        durations = durations,
        n_images = n_images,
        n_steps = length(plan),
    )
    return json
end

"Count frames and duration in a GIF file."
function count_frames_and_duration(path::AbstractString)
    output = ffprobe() do exe
        out = Pipe()
        cmd = `$exe -show_streams $path`
        run(pipeline(cmd, stdout=out, stderr=devnull))
        close(out.in)
        return read(out, String)
    end
    m = match(r"nb_frames=(\d+)", output)
    n_frames = parse(Int, m.captures[1])
    m = match(r"duration=(\d+.\d+)", output)
    duration = parse(Float64, m.captures[1])
    return n_frames, duration
end

# Define directory paths
PROBLEM_DIR = joinpath(@__DIR__, "dataset", "problems")
PLAN_DIR = joinpath(@__DIR__, "dataset", "plans")
STIMULI_DIR = joinpath(@__DIR__, "dataset", "stimuli")

# Load domain
domain = load_domain(joinpath(@__DIR__, "dataset", "domain.pddl"))

## Generate animations for single plan / stimulus

# Load problem
problem_path = joinpath(PROBLEM_DIR, "tutorial.pddl")
problem = load_problem(problem_path)

# Load or generate plan
plan_path = joinpath(PLAN_DIR, "tutorial.pddl")
if !isfile(plan_path)
    state = initstate(domain, problem)
    planner = AStarPlanner(FFHeuristic())
    sol = planner(domain, state, problem.goal)
    plan = collect(sol)
    splitpoints = Int[]
    save_plan(plan_path, plan, String[], splitpoints)
else
    plan, _, splitpoints = load_plan(plan_path)
end
pname = splitext(basename(plan_path))[1]

# Generate stimulus animation
path = joinpath(STIMULI_DIR, "full", "$pname.gif")
anim = generate_stim_anim(path, domain, problem, plan;
                          format="gif", framerate=25)

# Generate stimulus animation segments
mkpath(joinpath(STIMULI_DIR, "segments"))
basepath = joinpath(STIMULI_DIR, "segments", "$pname")
anims = generate_stim_anim_segments(
    basepath, domain, problem, plan, splitpoints;
    format="gif", framerate=25
)

# Generate storyboard plot for stimulus
RENDERER.resolution = (800, 700) # Adjust resolution to reduce whitespace
timesteps = [0; splitpoints; length(plan)]
storyboard = generate_stim_storyboard(
    domain, problem, plan, timesteps;
    subtitles = [
        "(i) Initial state",
        "(ii) Block 'e' is stacked on 'r'",
        "(iii) Block 't' is stacked on 'e'",
        "(iv) Block 'v' is unstacked from 'i'",
        "(v) Block 'i' is stacked on 't'",
        "(vi) Block 'l' is stacked on 'i'"
    ],
    xlabels = ["t = $t" for t in timesteps],
    xlabelsize = 20, subtitlesize = 24,
    n_rows = 2
)
resize!(storyboard, 1800, 1200) # Resize storyboard resolution
path = joinpath(@__DIR__, "$pname-storyboard.png")
save(path, storyboard)

# Generate stimuli JSON metadata
json = generate_stim_json(pname, problem, plan, splitpoints;
                          condition="tutorial")
JSON3.pretty(json)

## Generate all animations

mkpath(STIMULI_DIR)
mkpath(joinpath(STIMULI_DIR, "segments"))
problem_paths = readdir(PROBLEM_DIR, join=true)
filter!(p -> endswith(p, ".pddl") && startswith(basename(p), "problem"), problem_paths)
plan_paths = readdir(PLAN_DIR, join=true)
filter!(p -> endswith(p, ".pddl") && startswith(basename(p), "plan"), plan_paths)
all_metadata = []

for (problem_path, plan_path) in zip(problem_paths, plan_paths)
    # Load problem
    problem = load_problem(problem_path)
    # Load plan
    plan, _, splitpoints = load_plan(plan_path) 
    pname = splitext(basename(plan_path))[1]
    # Generate stimulus animation
    path = joinpath(STIMULI_DIR, "full", "$pname.gif")
    generate_stim_anim(path, domain, problem, plan)
    # Generate stimulus animation segments
    basepath = joinpath(STIMULI_DIR, "segments", "$pname")
    generate_stim_anim_segments(basepath, domain, problem, plan, splitpoints)
    # Generate stimuli JSON metadata
    json = generate_stim_json(pname, problem, plan, splitpoints)
    push!(all_metadata, json)
    # Sleep to avoid overloading the renderer
    sleep(0.5)
end

# Save JSON metadata
metadata_path = joinpath(STIMULI_DIR, "stimuli.json")
open(metadata_path, "w") do io
    JSON3.pretty(io, all_metadata, JSON3.AlignmentContext(indent=2))
end

## Generate stimuli ordering

using Random

groups = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16]]
orders = Vector{Int}[]
for i in 1:20
    cur_groups = deepcopy(groups)
    for j in 1:2
        idxs = Int[]
        # Sample two elements without replacement from each group
        for g in cur_groups
            for k in 1:2
                idx = rand(g)
                push!(idxs, idx)
                filter!(!=(idx), g)
            end
        end
        shuffle!(idxs)
        push!(orders, idxs)
    end
end

for i in 1:length(orders)
    orders[i] = orders[i] .- 1
end
