# Open-Ended Block Words

An implementation of open-ended goal inference via open-ended Sequential Inverse Plan Search (SIPS) in the Block Words domain.

For more details about open-ended SIPS, see [our paper](https://arxiv.org/abs/2407.16770):

> Tan Zhi-Xuan, Gloria Kang, Vikash Mansinghka, and Joshua B. Tenenbaum, 2024. **Infinite Ends from Finite Samples: Open-Ended Goal Inference as Top-Down Bayesian Filtering of Bottom-Up Proposals** In Proceedings of the 46th Annual Meeting of the Cognitive Science Society (CogSci 2024).

Model outputs, human data, and figures can be found in the following OSF repository: https://osf.io/bygwm/

## Setup

To set up the environment for this project, make sure this directory is set as the active environment. Then run the following commands in via `Pkg` mode in the Julia REPL:

```julia-repl
add https://github.com/probcomp/InversePlanning.jl.git
instantiate
```

## Project Structure

The files in this directory are organized as follows:

- The `dataset` directory contains all plans, problems, and stimuli.
- The `src` directory contains non-top-level source files.
- The `assets` directory contains word and word frequency lists.
- The `interface` directory contains the web interface for our experiment.
- `run_inference.jl` runs the inference algorithms and saves their outputs.
- `run_analysis.jl` analyzes model outputs in comparison with human data.
- `testbed.jl` is for experimenting with modeling and inference parameters
- `stimuli.jl` generates stimuli animations and metadata

The word list corresponds to the `3of6game` list from the [12Dicts](http://wordlist.aspell.net/12dicts/) package. Word frequencies for each word are derived from the Zipf frequency returned by the [wordfreq](https://github.com/rspeer/wordfreq) Python package. The Block Words domain was first introduced in [Ramizez & Geffner (IJCAI 2009)](https://www.ijcai.org/Proceedings/09/Papers/296.pdf) as a variant of the classic Blocksworld.