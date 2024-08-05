/* AngularJS App */
var experimentApp = angular.module(
  'experimentApp', ['ngSanitize', 'preloader'],
  function($locationProvider) {
    $locationProvider.html5Mode({enabled: true, requireBase: false});
  }
);

experimentApp.controller('ExperimentController',
  function ExperimentController($scope, $timeout, $location, preloader) {
    $scope.start_time = (new Date()).getTime();
    $scope.user_id = Date.now();
    $scope.user_count = 0;

    $scope.section = "instructions";
    $scope.inst_id = 0;
    $scope.stim_id = 0;
    $scope.part_id = -1;
    $scope.tutorial_text = ``;

    $scope.comprehension_response = "";
    $scope.valid_comprehension = false;

    $scope.cur_guess = "";
    $scope.response = { "guesses": [] };
    $scope.valid_guess = false;
    $scope.valid_response = false;

    $scope.exam_response = "";
    $scope.valid_exam = false;
    $scope.exam_results = [];
    $scope.exam_score = 0;
    $scope.exam_done = false;
    $scope.last_exam_correct = false;
    $scope.last_exam_response = "";
    
    $scope.ratings = [];
    $scope.true_goal = "";
    $scope.stim_reward = 0;
    $scope.total_reward = 0;

    $scope.show_rhs = true;
    $scope.anim_complete = true;
    
    $scope.replaying = false;
    $scope.replay_id = 0;
   
    $scope.log = function(...args) {
      if ($location.search().debug == "true") {
        console.log(...args);
      }
    }

    $scope.store_to_db = function(key, val) {
      $scope.log("Storing " + key + " with " + JSON.stringify(val));
      if ($location.search().local != "true") {
        resultsRef.child(key).set(val);
      }
    }

    $scope.get_counter = async function () {
      if ($location.search().local == "true") {
        let max = $scope.stimuli_sets.length
        return Math.floor(Math.random() * max);
      } else {
        return counterRef.child(counterKey).once("value", function (snapshot) {
          $scope.user_count = snapshot.val();
        }).then(() => { return $scope.user_count; });
      }
    }
    
    $scope.increment_counter = function() {
      if ($location.search().local == "true") {
        return;
      } else {
        counterRef.child(counterKey).set($scope.user_count + 1);
      }
    }

    $scope.reload_gif = function () {
      if ($scope.section == "stimuli") {
        var id = document.getElementById("stimulus-img");
      } else {
        var id = document.getElementById("instruction-img")
      }
      id.src = id.src;
    }

    $scope.replay_all = function () {
      if ($scope.section == "stimuli" && $scope.cur_stim().n_images > 1) {
        var stim = $scope.cur_stim();
        let start_dur = stim.durations[1] * 1000;
        $scope.replay_id = 1;
        $scope.replaying = true;
        $scope.reload_gif();
        var advance_replay = function () {
          if ($scope.replaying && $scope.replay_id < $scope.part_id) {
            $scope.replay_id += 1;
            $scope.reload_gif();
            let dur = stim.durations[$scope.replay_id] * 1000;
            $timeout(advance_replay, dur);
          } else {
            $scope.replaying = false;
            $scope.replay_id = 0;
          }
        }
        $timeout(advance_replay, start_dur);
      }
    }

    $scope.validate_comprehension = function (ans) {
      $scope.comprehension_response = ans;
      let index = $scope.instructions[$scope.inst_id].answer;
      $scope.valid_comprehension = ans == $scope.instructions[$scope.inst_id].options[index];
    }
    $scope.validate_exam = function (ans) {
      $scope.exam_response = ans;
      $scope.valid_exam = true;
    }
    $scope.validate_guess = function () {
      var valid_chars;
      var pattern;
      if ($scope.section == "stimuli") {
        valid_chars = $scope.cur_stim().characters;
      } else if ($scope.section == "instructions" && $scope.is_tutorial()) {
        valid_chars = $scope.instructions[$scope.inst_id].characters;
      } else {
        $scope.valid_guess = true;
        return;
      }
      if (typeof valid_chars === "undefined") {
        $scope.valid_guess = true;
        return;
      }
      pattern = RegExp("^[" + valid_chars + "]{3,8}$");
      if (pattern.test($scope.cur_guess)) {
        let char_counts = $scope.count_chars(valid_chars);
        let guess_counts = $scope.count_chars($scope.cur_guess);
        $scope.valid_guess = $scope.bag_contains(char_counts, guess_counts);
      } else {
        $scope.valid_guess = false;
      }
    }
    $scope.validate_response = function () {
      $scope.valid_response = $scope.response.guesses.length > 0;
    }
    $scope.submit_guess = function () {
      if ($scope.valid_guess) {
        $scope.response.guesses.push($scope.cur_guess);
        $scope.cur_guess = "";
        $scope.valid_guess = false;
        $scope.validate_response();
      }
    }
    $scope.remove_guess = function (idx) {
      $scope.response.guesses.splice(idx, 1);
      $scope.validate_response();
    }
    $scope.remove_guesses = function () {
      $scope.response.guesses = [];
      $scope.validate_response();
    }
    $scope.count_chars = function (str) {
      var counts = {};
      for (let i = 0; i < str.length; i++) {
        let ch = str[i];
        if (ch in counts) {
          counts[ch] += 1;
        } else {
          counts[ch] = 1;
        }
      }
      return counts;
    }
    $scope.bag_contains = function (counts1, counts2) {
      for (let ch in counts2) {
        if (ch in counts1) {
          if (counts2[ch] > counts1[ch]) {
            return false;
          }
        } else {
          return false;
        }
      }
      return true;
    }

    $scope.advance = function () {
      if ($scope.section == "instructions") {
        $scope.advance_instructions()
      } else if ($scope.section == "stimuli") {
        $scope.advance_stimuli()
      } else if ($scope.section == "endscreen") {
        // Do nothing
      }
    };

    $scope.advance_instructions = function () {
      if ($scope.inst_id == $scope.instructions.length - 1) {
        // Advance to stimuli section
        $scope.section = "stimuli";
        $scope.stim_id = 0;
        $scope.part_id = 0;
        $scope.stim_reward = 0;
        $scope.ratings = [];
        $scope.true_goal = $scope.cur_stim().goal;
        $scope.cur_guess = "";
        $scope.valid_guess = false;
        $scope.response = { "guesses": [] };
        $scope.valid_response = false;
        $scope.start_time = (new Date()).getTime();;
        $scope.anim_complete = true;
      } else if ($scope.instructions[$scope.inst_id].exam_end) {
        // Store exam results for initial attempt
        if (!$scope.exam_done) {
          let exam_data = {
            "results": $scope.exam_results,
            "score": $scope.exam_score
          }
          $scope.log("Exam Results: " + exam_data.results);
          $scope.log("Exam Score: " + exam_data.score);
          $scope.store_to_db($scope.user_id + "/exam", exam_data);
          $scope.exam_done = true;
        }
        // Loop back to start of exam if not all questions are correct
        if ($scope.exam_score < $scope.exam_results.length) {
          $scope.inst_id = $scope.instructions[$scope.inst_id].exam_start_id;
        } else {
          $scope.inst_id = $scope.inst_id + 1;
        }
        $scope.exam_results = [];
        $scope.exam_score = 0;
      } else {
        // Score exam question
        if ($scope.instructions[$scope.inst_id].exam) {
          let ans = $scope.instructions[$scope.inst_id].options[$scope.instructions[$scope.inst_id].answer];
          let correct = ans === $scope.exam_response;
          $scope.exam_results.push(correct);
          $scope.exam_score = $scope.exam_results.filter(correct => correct == true).length
          $scope.last_exam_correct = correct;
          $scope.last_exam_response = $scope.exam_response;
        }
        // Reset responses if not in a tutorial
        if (!$scope.instructions[$scope.inst_id].tutorial) {
          $scope.response = { "guesses": [] };
          $scope.valid_response = false;
        }
        // Increment instruction counter
        $scope.inst_id = $scope.inst_id + 1;
        // Delay RHS display
        if ($scope.instructions[$scope.inst_id].delay > 0) {
          $scope.show_rhs = false;
          $scope.anim_complete = false;
          $timeout(function() {$scope.show_rhs = true; $scope.anim_complete = true;},
                   $scope.instructions[$scope.inst_id].delay);
        }
      }
      // Reset responses and validation flags
      $scope.cur_guess = "";
      $scope.valid_guess = false;
      $scope.comprehension_response = "";
      $scope.valid_comprehension = false;
      $scope.exam_response = "";
      $scope.valid_exam = false;
    };

    $scope.advance_stimuli = function () {
      if ($scope.stim_id == $scope.stimuli_set.length) {
        // Advance to endscreen
        $scope.section = "endscreen"
        if ($scope.total_reward > 0) {
          $scope.total_payment = ($scope.total_reward / 10).toFixed(2)
        } else {
          $scope.total_payment = 0.0
        }
        $scope.total_reward = $scope.total_reward.toFixed(1)
        $scope.store_to_db($scope.user_id + "/total_reward", $scope.total_reward);
        $scope.store_to_db($scope.user_id + "/total_payment", $scope.total_payment);
      } else if ($scope.part_id < 0) {
        // Advance to start of stimulus
        $scope.part_id = $scope.part_id + 1;  
        $scope.ratings = [];
        $scope.stim_reward = 0;
        $scope.true_goal = $scope.cur_stim().goal;
        $scope.start_time = (new Date()).getTime();
        $scope.anim_complete = true;
      } else if ($scope.part_id < $scope.cur_stim().n_images) {
        // Advance to next part
        if ($scope.part_id > 0) {
          var ratings = $scope.compute_ratings($scope.response);
          $scope.ratings.push(ratings);
          $scope.stim_reward += ratings.reward;
          $scope.log("Step reward: " + ratings.reward);
        }
        $scope.part_id = $scope.part_id + 1;
        $scope.start_time = (new Date()).getTime();
        // Advance to next stimulus
        if ($scope.part_id == $scope.cur_stim().timesteps.length + 1) {
          // Store ratings
          $scope.total_reward += $scope.stim_reward;
          $scope.store_to_db($scope.user_id + "/" + $scope.cur_stim().name, $scope.ratings);
          $scope.store_to_db($scope.user_id + "/" + $scope.cur_stim().name + "/reward", $scope.stim_reward);
          $scope.log("Stimulus reward: " + $scope.stim_reward);
          $scope.log("Total reward: " + $scope.total_reward);
          // Increment stimulus counter
          $scope.part_id = -1;
          $scope.stim_id = $scope.stim_id + 1;
          $scope.anim_complete = true;
          // Preload images for new stimulus
          preloader.preloadImages($scope.cur_stim_images()).then(
            function handleResolve(imglocs) {console.info("Preloaded stimulus.");}
          );
        } else {
          // Begin timer to set animation completion flag
          $scope.anim_complete = false;
          let anim_dur = $scope.cur_stim().durations[$scope.part_id] * 1000;
          $timeout(function() {$scope.anim_complete = true;}, anim_dur);
        }
      }
      // Reset replay status
      $scope.replaying = false;
      $scope.replay_id = 0;
      // Reset response and validation flags
      $scope.cur_guess = "";
      $scope.valid_guess = false;
      if ($scope.part_id < 0) {
        $scope.response = { "guesses": [] };
        $scope.valid_response = false;
      }
      // Focus on input text box
      if ($scope.part_id > 0) {
        $timeout(function() {document.getElementById("guess-input").focus();}, 50);
      }
    };

    $scope.compute_ratings = function (response) {
      // Count number of guesses equal to true goal
      let n_correct = response.guesses.filter(g => g == $scope.true_goal).length;
      let n_guesses = response.guesses.length;
      // Compute reward
      let reward = n_correct / n_guesses;
      rating = {
        "timestep": $scope.cur_stim().timesteps[$scope.part_id - 1],
        "time_spent": ((new Date()).getTime() - $scope.start_time) / 1000.,
        "guesses": Array.from(response.guesses),
        "n_correct": n_correct,
        "n_guesses": n_guesses,
        "reward": reward
      }
      return rating;
    };

    $scope.instruction_has_text = function () {
      return $scope.instructions[$scope.inst_id].text != null
    };
    $scope.instruction_has_image = function () {
      return $scope.instructions[$scope.inst_id].image != null
    };
    $scope.instruction_has_question = function () {
      return $scope.instructions[$scope.inst_id].question != null
    };
    $scope.is_exam = function () {
      return $scope.instructions[$scope.inst_id].exam == true
    };
    $scope.is_feedback = function () {
      return $scope.instructions[$scope.inst_id].feedback == true
    };
    $scope.is_exam_end = function () {
      return $scope.instructions[$scope.inst_id].exam_end == true
    };
    $scope.is_tutorial = function () {
      return $scope.instructions[$scope.inst_id].tutorial == true
    };
    $scope.hide_questions = function () {
      return $scope.instructions[$scope.inst_id].questions_show == false
    };
    $scope.disable_questions = function () {
      return $scope.section == "stimuli" && !$scope.anim_complete;
    };

    $scope.cur_stim = function () {
      let idx = $scope.stimuli_set[$scope.stim_id];
      return $scope.stimuli[idx];
    };
    $scope.prev_stim = function () {
      let idx = $scope.stimuli_set[$scope.stim_id - 1];
      return $scope.stimuli[idx];
    };

    $scope.stimuli_dir = "stimuli/";
    $scope.last_image = $scope.stimuli_dir + "default.gif";

    $scope.cur_stim_image = function () {
      if ($scope.part_id < 0) {
        let stim = $scope.prev_stim();
        if (stim == undefined) {
          return $scope.last_image;
        } else {
          return $scope.stimuli_dir + stim.images[stim.n_images - 1];
        }
      } else if ($scope.replaying) {
        let stim = $scope.cur_stim();
        if (stim == undefined) {
          return $scope.last_image;
        } else {       
          return $scope.stimuli_dir + stim.images[$scope.replay_id];
        }
      } else {
        let stim = $scope.cur_stim();
        if (stim == undefined) {
          return $scope.last_image;
        } else {       
          return $scope.stimuli_dir + stim.images[$scope.part_id];
        }
      }
    };
    $scope.cur_stim_images = function () {
      let stim = $scope.cur_stim();
      if (stim == undefined) {
        return [];
      } else {
        return stim.images.map(img => $scope.stimuli_dir + img);
      }
    }

    $scope.stimuli_set = [];
    $scope.set_stimuli = async function () {
      if ($location.search().test_all == "true") {
        $scope.stimuli_set = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
      } else {
        let count = await $scope.get_counter();
        $scope.stimuli_set = $scope.stimuli_sets[count % $scope.stimuli_sets.length];
        $scope.increment_counter();
      }
      $scope.log("stimuli set = " + $scope.stimuli_set);
      preloader.preloadImages($scope.cur_stim_images()).then(
        function handleResolve(imglocs) {console.info("Preloaded stimulus.");}
      );
    };

    $scope.stimuli_sets = [
      [2, 14, 4, 10, 5, 0, 9, 13],
      [8, 3, 7, 12, 1, 11, 6, 15],
      [15, 13, 4, 7, 0, 3, 11, 10],
      [5, 9, 8, 1, 14, 6, 2, 12],
      [14, 2, 4, 15, 10, 8, 0, 7],
      [13, 11, 3, 9, 1, 5, 12, 6],
      [8, 1, 14, 9, 5, 7, 13, 3],
      [2, 6, 11, 4, 12, 10, 15, 0],
      [6, 12, 3, 10, 8, 4, 15, 2],
      [0, 13, 11, 9, 7, 5, 14, 1],
      [6, 3, 9, 11, 2, 7, 12, 13],
      [5, 15, 1, 8, 4, 0, 10, 14],
      [8, 14, 13, 6, 4, 9, 1, 0],
      [11, 7, 15, 12, 10, 3, 5, 2],
      [8, 13, 3, 4, 12, 7, 1, 11],
      [9, 0, 5, 6, 2, 14, 10, 15],
      [8, 2, 15, 13, 4, 3, 11, 7],
      [5, 12, 10, 9, 14, 0, 6, 1],
      [11, 15, 9, 0, 4, 6, 12, 1],
      [10, 2, 13, 5, 7, 8, 14, 3],
      [11, 13, 3, 15, 6, 1, 9, 4],
      [7, 5, 10, 14, 2, 8, 0, 12],
      [6, 15, 0, 11, 12, 8, 7, 1],
      [14, 5, 13, 4, 9, 3, 10, 2],
      [14, 10, 5, 0, 7, 1, 13, 11],
      [15, 2, 4, 3, 8, 9, 6, 12],
      [13, 6, 1, 14, 2, 10, 4, 8],
      [11, 12, 15, 0, 7, 3, 9, 5],
      [3, 14, 9, 10, 15, 6, 5, 0],
      [13, 7, 12, 2, 4, 11, 8, 1],
      [10, 11, 15, 1, 6, 14, 3, 5],
      [2, 7, 13, 4, 0, 12, 8, 9],
      [2, 15, 7, 5, 13, 0, 10, 8],
      [9, 1, 6, 4, 3, 11, 14, 12],
      [11, 0, 14, 8, 6, 12, 1, 7],
      [13, 10, 15, 3, 9, 5, 4, 2],
      [8, 5, 11, 2, 3, 12, 14, 7],
      [13, 15, 1, 6, 9, 4, 0, 10],
      [6, 15, 11, 12, 4, 1, 9, 0],
      [7, 8, 13, 14, 10, 3, 5, 2]
    ];

    $scope.instructions = [
      {
        text: `Welcome to our word guessing game! <br>
              <br>
              Before you begin your task, you'll complete a brief guided tutorial (~ 3 minutes) to understand the game.<br>
              <br>
              Press <strong>Next</strong> to continue.`,
      },
      {
        text: `Your friend is moving blocks to spell an English word in a stack (first letter on top).<br>
              <br>
              You are watching and trying to guess what the word is before your friend finishes spelling.<br>
              <br>
              Hit <strong>Next</strong> to watch your friend play, and try to guess the word.
              `,
        image: "stimuli/demo-0.gif"
      },
      {
        text: ``,
        image: "stimuli/demo-1.gif",
        question: `Watch the entire game. What word is your friend spelling?`,
        options: ["power", "cower", "crow", "core", "pore"],
        answer: 3
      },
      {
        text: `Now, your task is to watch someone stacking blocks, and when they pause, guess which word they are trying to spell.
              <br><br>
              <strong>How to guess?</strong><br>
              <br>
              You will be given a given a text box to type in your guesses.
              You can type in any word between 3-8 letters long that you think is being spelled.
              You can make <em>multiple guesses</em> if you are unsure.`
      },
      {
        text: `Let's do a practice run, just so you're familiarized.`,
      },
      {
        text: `First, you'll get a chance to look at the available letters.<br>
              <br>
              In the next step, the player will move a few blocks.<br>
              <br>
              Press <strong>Next</strong> to continue, then watch closely.
              `,
        image: "stimuli/tutorial-0.gif",
        tutorial: true,
        characters: "lutviawroe",
        questions_show: false
      },
      {
        text: `What do you think? If you think that <strong>multiple</strong> words are possible, you can submit multiple guesses. <br>
              <br>
              To submit a guess after typing, you can use the <strong>Submit</strong> button, or press <strong>Enter</strong> on your keyboard.
              `,
        image: "stimuli/tutorial-1.gif",
        delay: 2800,
        tutorial: true,
        characters: "lutviawroe",
        questions_show: true
      },
      {
        text: `How about now? Do your guesses change? <br>
              <br>
              If some of your previous guesses no longer make sense, you can <strong>remove</strong> them by clicking the ⨂ button next to each guess.
              `,
        image: "stimuli/tutorial-2.gif",
        delay: 1800,
        tutorial: true,
        characters: "lutviawroe",
        questions_show: true
      },
      {
        text: `Now the player has unstacked block <strong>v</strong> from <strong>i</strong>, then stacked it on <strong>w</strong>. Does this make any word more or less likely? <br>
              <br>
              Remember, you can both <strong>add</strong> and <strong>remove</strong> guesses at each step.`,
        image: "stimuli/tutorial-3.gif",
        delay: 1300,
        tutorial: true,
        characters: "lutviawroe",
        questions_show: true
      },
      {
        text: `Okay, one last chance to guess. Do you think you know the answer?`,
        image: "stimuli/tutorial-4.gif",
        delay: 1300,
        tutorial: true,
        characters: "lutviawroe",
        questions_show: true
      },      
      {
        text: `As you might have guessed, the word being spelled was <strong>liter</strong>!`,
        image: "stimuli/tutorial-5.gif",
      },
      {
        text: `You've now finished the practice round! <br>
              <br>
              <strong>Bonus Points</strong><br>
              As you play, you can earn <strong>bonus points</strong> if you guess correctly:
              <ul>
              <li>Each time you make guesses, you earn <strong>1 point</strong> if you guess the correct word with <strong>only 1 guess.</strong></li>
              <li>If you make <strong>N guesses</strong>, and one of them is correct, you will get <strong>1/N points</strong>.</li>
              <li>If <strong>none</strong> of your guesses are correct, you will get <strong>0 points</strong>.</li>
              </ul>
              This means that if you're <strong>certain</strong> what the word is, you should <strong>only guess</strong> that word, and <strong>remove</strong> other guesses.
              If only 2 words seem likely, you should guess those 2 words, and remove the rest.<br>
              <br>
              For every <strong>10 points</strong> you earn, you will recieve <strong>$1.00</strong> in bonus payment.
              `
      },
      {
        text: `<strong>Comprehension Questions</strong> <br>
               <br>
               For the last part of the tutorial, we will ask 5 quick questions to check your understanding of the task.<br>
               <br>
               Answer <strong>all questions correctly</strong> in order to proceed to the main experiment.
               You can retake the quiz as many times as necessary.
              `
      },
      {
        text: `<strong>Question 1/5:</strong> What is the purpose of your task?`,
        options: [
          "Spell a word by stacking blocks.",
          "Stack blocks to spell as many words as possible.",
          "Try to guess what word is being spelled."
        ],
        answer: 2,
        exam: true
      },
      {
        text: `<strong>Question 1/5:</strong> What is the purpose of your task?`,
        options: [
          "Spell a word by stacking blocks.",
          "Stack blocks to spell as many words as possible.",
          "Try to guess what word is being spelled."
        ],
        answer: 2,
        feedback: true
      },
      {
        text: `<strong>Question 2/5:</strong> In a game, how many words is your friend trying to spell?`,
        options: [
          "Just 1 word.",
          "2 words.",
          "More than 2 words."
        ],
        answer: 0,
        exam: true
      },
      {
        text: `<strong>Question 2/5:</strong>  In a game, how many words is your friend trying to spell?`,
        options: [
          "Just 1 word.",
          "2 words.",
          "More than 2 words."
        ],
        answer: 0,
        feedback: true
      },
      {
        text: `<strong>Question 3/5:</strong>  How many words can you guess at each step?`,
        options: [
          "Only 1 word.",
          "Up to 2 words.",
          "As many words as I think are likely."
        ],
        answer: 2,
        exam: true
      },
      {
        text: `<strong>Question 3/5:</strong>  How many words can you guess at each step?`,
        options: [
          "Only 1 word.",
          "Up to 2 words.",
          "As many words as I think are likely."
        ],
        answer: 2,
        feedback: true
      },
      {
        text: `<strong>Question 4/5:</strong> After watching several moves, you think the words 
              <em>'liter'</em>, <em>'water'</em> and <em>'later'</em> are likely, but you're not sure which is correct.
              Which of these words should you enter as guesses?
              `,
        options: [
          "Guess only 1 word, and hope I'm right.",
          "All 3 words, since I don't know which is correct.",
          "As many words as possible, even if they're unlikely."
        ],
        answer: 1,
        exam: true
      },
      {
        text: `<strong>Question 4/5:</strong> After watching several moves, you think the words 
              <em>'liter'</em>, <em>'water'</em> and <em>'later'</em> are likely, but you're not sure which is correct.
              Which of these words should you enter as guesses?
              `,
        options: [
          "Guess only 1 word, and hope I'm right.",
          "All 3 words, since I don't know which is correct.",
          "As many words as possible, even if they're unlikely."
        ],
        answer: 1,
        feedback: true
      },
      {
        text: `<strong>Question 5/5:</strong> In a previous step, you added the word <em>'over'</em>
              as one of your guesses. After watching the next move, you <em>no longer</em>
              think that <em>'over'</em> is likely. What should you do to maximize your
              bonus points?
              `,
        options: [
          "Keep <em>'over'</em> in my guesses.",
          "Remove <em>'over'</em> from my guesses.",
          "Add even more words to my guesses."
        ],
        answer: 1,
        exam: true
      },
      {
        text: `<strong>Question 5/5:</strong> In a previous step, you added the word <em>'over'</em>
              as one of your guesses. After watching the next move, you <em>no longer</em>
              think that <em>'over'</em> is likely. What should you do to maximize your
              bonus points?
              `,
        options: [
          "Keep <em>'over'</em> in my guesses.",
          "Remove <em>'over'</em> from my guesses.",
          "Add even more words to my guesses."
        ],
        answer: 1,
        feedback: true
      },
      {
        exam_end: true,
        exam_start_id: 13
      },
      {
        text: `Congrats! You've finished the tutorial. Your task is to guess words for <strong>8 different rounds</strong>.<br>
        <br>
        Ready to start? Press <strong>Next</strong> to continue!`
      }
    ];
  
    instruction_images =
      $scope.instructions.filter(i => i.image !== undefined).map(i => i.image);
    preloader.preloadImages(instruction_images).then(
      function handleResolve(imglocs) {console.info("Preloaded instructions.");});

    // Skip to end of tutorial if flag is specified
    if ($location.search().skip_tutorial == "true") {
      $scope.inst_id = $scope.instructions.length - 1;
    }
  
    $scope.stimuli = [
      {
        "name": "plan-easy-1",
        "condition": "easy",
        "goal": "yeast",
        "characters": "layestfbm",
        "timesteps": [
          4,
          6,
          8,
          10
        ],
        "images": [
          "plan-easy-1-0.gif",
          "plan-easy-1-1.gif",
          "plan-easy-1-2.gif",
          "plan-easy-1-3.gif",
          "plan-easy-1-4.gif",
          "plan-easy-1-5.gif"
        ],
        "frame_counts": [
          1,
          41,
          20,
          22,
          24,
          30
        ],
        "durations": [
          0.1,
          1.64,
          0.8,
          0.88,
          0.96,
          1.2
        ],
        "n_images": 6,
        "n_steps": 12
      },
      {
        "name": "plan-easy-2",
        "condition": "easy",
        "goal": "flame",
        "characters": "aiseflnbm",
        "timesteps": [
          2,
          4,
          6,
          8
        ],
        "images": [
          "plan-easy-2-0.gif",
          "plan-easy-2-1.gif",
          "plan-easy-2-2.gif",
          "plan-easy-2-3.gif",
          "plan-easy-2-4.gif"
        ],
        "frame_counts": [
          1,
          24,
          24,
          22,
          20
        ],
        "durations": [
          0.1,
          0.96,
          0.96,
          0.88,
          0.8
        ],
        "n_images": 5,
        "n_steps": 8
      },
      {
        "name": "plan-easy-3",
        "condition": "easy",
        "goal": "know",
        "characters": "kbhnsewot",
        "timesteps": [
          2,
          4,
          6,
          8,
          10
        ],
        "images": [
          "plan-easy-3-0.gif",
          "plan-easy-3-1.gif",
          "plan-easy-3-2.gif",
          "plan-easy-3-3.gif",
          "plan-easy-3-4.gif",
          "plan-easy-3-5.gif",
          "plan-easy-3-6.gif"
        ],
        "frame_counts": [
          1,
          25,
          22,
          28,
          17,
          25,
          29
        ],
        "durations": [
          0.1,
          1.0,
          0.88,
          1.12,
          0.68,
          1.0,
          1.16
        ],
        "n_images": 7,
        "n_steps": 12
      },
      {
        "name": "plan-easy-4",
        "condition": "easy",
        "goal": "drains",
        "characters": "dtainsbrp",
        "timesteps": [
          4,
          8,
          10,
          12,
          14
        ],
        "images": [
          "plan-easy-4-0.gif",
          "plan-easy-4-1.gif",
          "plan-easy-4-2.gif",
          "plan-easy-4-3.gif",
          "plan-easy-4-4.gif",
          "plan-easy-4-5.gif",
          "plan-easy-4-6.gif"
        ],
        "frame_counts": [
          1,
          68,
          37,
          19,
          27,
          27,
          34
        ],
        "durations": [
          0.1,
          2.72,
          1.48,
          0.76,
          1.08,
          1.08,
          1.36
        ],
        "n_images": 7,
        "n_steps": 16
      },
      {
        "name": "plan-irrational-1",
        "condition": "irrational",
        "goal": "stake",
        "characters": "mislektafr",
        "timesteps": [
          2,
          4,
          6,
          8,
          10,
          12,
          14
        ],
        "images": [
          "plan-irrational-1-0.gif",
          "plan-irrational-1-1.gif",
          "plan-irrational-1-2.gif",
          "plan-irrational-1-3.gif",
          "plan-irrational-1-4.gif",
          "plan-irrational-1-5.gif",
          "plan-irrational-1-6.gif",
          "plan-irrational-1-7.gif"
        ],
        "frame_counts": [
          1,
          39,
          37,
          30,
          19,
          17,
          22,
          27
        ],
        "durations": [
          0.1,
          1.56,
          1.48,
          1.2,
          0.76,
          0.68,
          0.88,
          1.08
        ],
        "n_images": 8,
        "n_steps": 14
      },
      {
        "name": "plan-irrational-2",
        "condition": "irrational",
        "goal": "brink",
        "characters": "dlbisrpknth",
        "timesteps": [
          2,
          4,
          6,
          8,
          10,
          12
        ],
        "images": [
          "plan-irrational-2-0.gif",
          "plan-irrational-2-1.gif",
          "plan-irrational-2-2.gif",
          "plan-irrational-2-3.gif",
          "plan-irrational-2-4.gif",
          "plan-irrational-2-5.gif",
          "plan-irrational-2-6.gif",
          "plan-irrational-2-7.gif"
        ],
        "frame_counts": [
          1,
          20,
          20,
          29,
          23,
          24,
          30,
          38
        ],
        "durations": [
          0.1,
          0.8,
          0.8,
          1.16,
          0.92,
          0.96,
          1.2,
          1.52
        ],
        "n_images": 8,
        "n_steps": 14
      },
      {
        "name": "plan-irrational-3",
        "condition": "irrational",
        "goal": "rough",
        "characters": "nroeiuchgts",
        "timesteps": [
          4,
          6,
          8,
          10,
          12,
          14,
          16
        ],
        "images": [
          "plan-irrational-3-0.gif",
          "plan-irrational-3-1.gif",
          "plan-irrational-3-2.gif",
          "plan-irrational-3-3.gif",
          "plan-irrational-3-4.gif",
          "plan-irrational-3-5.gif",
          "plan-irrational-3-6.gif",
          "plan-irrational-3-7.gif"
        ],
        "frame_counts": [
          1,
          63,
          17,
          23,
          26,
          15,
          33,
          20
        ],
        "durations": [
          0.1,
          2.52,
          0.68,
          0.92,
          1.04,
          0.6,
          1.32,
          0.8
        ],
        "n_images": 8,
        "n_steps": 16
      },
      {
        "name": "plan-irrational-4",
        "condition": "irrational",
        "goal": "reaction",
        "characters": "actionufres",
        "timesteps": [
          2,
          4,
          6,
          8,
          10,
          12
        ],
        "images": [
          "plan-irrational-4-0.gif",
          "plan-irrational-4-1.gif",
          "plan-irrational-4-2.gif",
          "plan-irrational-4-3.gif",
          "plan-irrational-4-4.gif",
          "plan-irrational-4-5.gif",
          "plan-irrational-4-6.gif",
          "plan-irrational-4-7.gif"
        ],
        "frame_counts": [
          1,
          17,
          21,
          15,
          25,
          27,
          20,
          25
        ],
        "durations": [
          0.1,
          0.68,
          0.84,
          0.6,
          1.0,
          1.08,
          0.8,
          1.0
        ],
        "n_images": 8,
        "n_steps": 14
      },
      {
        "name": "plan-switch-1",
        "condition": "switch",
        "goal": "can",
        "characters": "usontgachi",
        "timesteps": [
          2,
          4,
          6,
          8,
          10
        ],
        "images": [
          "plan-switch-1-0.gif",
          "plan-switch-1-1.gif",
          "plan-switch-1-2.gif",
          "plan-switch-1-3.gif",
          "plan-switch-1-4.gif",
          "plan-switch-1-5.gif"
        ],
        "frame_counts": [
          1,
          20,
          20,
          20,
          20,
          20
        ],
        "durations": [
          0.1,
          0.8,
          0.8,
          0.8,
          0.8,
          0.8
        ],
        "n_images": 6,
        "n_steps": 10
      },
      {
        "name": "plan-switch-2",
        "condition": "switch",
        "goal": "short",
        "characters": "peinoghtrs",
        "timesteps": [
          2,
          4,
          6,
          8,
          10,
          12,
          14
        ],
        "images": [
          "plan-switch-2-0.gif",
          "plan-switch-2-1.gif",
          "plan-switch-2-2.gif",
          "plan-switch-2-3.gif",
          "plan-switch-2-4.gif",
          "plan-switch-2-5.gif",
          "plan-switch-2-6.gif",
          "plan-switch-2-7.gif",
          "plan-switch-2-8.gif"
        ],
        "frame_counts": [
          1,
          20,
          15,
          20,
          20,
          15,
          29,
          20,
          27
        ],
        "durations": [
          0.1,
          0.8,
          0.6,
          0.8,
          0.8,
          0.6,
          1.16,
          0.8,
          1.08
        ],
        "n_images": 9,
        "n_steps": 16
      },
      {
        "name": "plan-switch-3",
        "condition": "switch",
        "goal": "mother",
        "characters": "erhmotcusa",
        "timesteps": [
          2,
          4,
          6,
          8,
          10,
          12
        ],
        "images": [
          "plan-switch-3-0.gif",
          "plan-switch-3-1.gif",
          "plan-switch-3-2.gif",
          "plan-switch-3-3.gif",
          "plan-switch-3-4.gif",
          "plan-switch-3-5.gif",
          "plan-switch-3-6.gif",
          "plan-switch-3-7.gif"
        ],
        "frame_counts": [
          1,
          24,
          19,
          15,
          22,
          19,
          24,
          29
        ],
        "durations": [
          0.1,
          0.96,
          0.76,
          0.6,
          0.88,
          0.76,
          0.96,
          1.16
        ],
        "n_images": 8,
        "n_steps": 14
      },
      {
        "name": "plan-switch-4",
        "condition": "switch",
        "goal": "clone",
        "characters": "aohlectgns",
        "timesteps": [
          2,
          4,
          6,
          8,
          10,
          12
        ],
        "images": [
          "plan-switch-4-0.gif",
          "plan-switch-4-1.gif",
          "plan-switch-4-2.gif",
          "plan-switch-4-3.gif",
          "plan-switch-4-4.gif",
          "plan-switch-4-5.gif",
          "plan-switch-4-6.gif",
          "plan-switch-4-7.gif"
        ],
        "frame_counts": [
          1,
          23,
          18,
          17,
          20,
          20,
          28,
          24
        ],
        "durations": [
          0.1,
          0.92,
          0.72,
          0.68,
          0.8,
          0.8,
          1.12,
          0.96
        ],
        "n_images": 8,
        "n_steps": 14
      },
      {
        "name": "plan-uncommon-1",
        "condition": "uncommon",
        "goal": "chump",
        "characters": "cbjhsapmutl",
        "timesteps": [
          4,
          6,
          8,
          10,
          12
        ],
        "images": [
          "plan-uncommon-1-0.gif",
          "plan-uncommon-1-1.gif",
          "plan-uncommon-1-2.gif",
          "plan-uncommon-1-3.gif",
          "plan-uncommon-1-4.gif",
          "plan-uncommon-1-5.gif",
          "plan-uncommon-1-6.gif"
        ],
        "frame_counts": [
          1,
          41,
          21,
          22,
          25,
          27,
          35
        ],
        "durations": [
          0.1,
          1.64,
          0.84,
          0.88,
          1.0,
          1.08,
          1.4
        ],
        "n_images": 7,
        "n_steps": 14
      },
      {
        "name": "plan-uncommon-2",
        "condition": "uncommon",
        "goal": "aft",
        "characters": "dafrtshilo",
        "timesteps": [
          2,
          4,
          6,
          8
        ],
        "images": [
          "plan-uncommon-2-0.gif",
          "plan-uncommon-2-1.gif",
          "plan-uncommon-2-2.gif",
          "plan-uncommon-2-3.gif",
          "plan-uncommon-2-4.gif"
        ],
        "frame_counts": [
          1,
          30,
          23,
          22,
          17
        ],
        "durations": [
          0.1,
          1.2,
          0.92,
          0.88,
          0.68
        ],
        "n_images": 5,
        "n_steps": 8
      },
      {
        "name": "plan-uncommon-3",
        "condition": "uncommon",
        "goal": "wizard",
        "characters": "wazrhdgliue",
        "timesteps": [
          2,
          4,
          6,
          8,
          10,
          12,
          14
        ],
        "images": [
          "plan-uncommon-3-0.gif",
          "plan-uncommon-3-1.gif",
          "plan-uncommon-3-2.gif",
          "plan-uncommon-3-3.gif",
          "plan-uncommon-3-4.gif",
          "plan-uncommon-3-5.gif",
          "plan-uncommon-3-6.gif",
          "plan-uncommon-3-7.gif",
          "plan-uncommon-3-8.gif"
        ],
        "frame_counts": [
          1,
          31,
          20,
          24,
          20,
          29,
          27,
          20,
          40
        ],
        "durations": [
          0.1,
          1.24,
          0.8,
          0.96,
          0.8,
          1.16,
          1.08,
          0.8,
          1.6
        ],
        "n_images": 9,
        "n_steps": 16
      },
      {
        "name": "plan-uncommon-4",
        "condition": "uncommon",
        "goal": "banish",
        "characters": "rdvisfhngab",
        "timesteps": [
          4,
          6,
          8,
          10,
          12
        ],
        "images": [
          "plan-uncommon-4-0.gif",
          "plan-uncommon-4-1.gif",
          "plan-uncommon-4-2.gif",
          "plan-uncommon-4-3.gif",
          "plan-uncommon-4-4.gif",
          "plan-uncommon-4-5.gif",
          "plan-uncommon-4-6.gif"
        ],
        "frame_counts": [
          1,
          58,
          35,
          24,
          32,
          31,
          36
        ],
        "durations": [
          0.1,
          2.32,
          1.4,
          0.96,
          1.28,
          1.24,
          1.44
        ],
        "n_images": 7,
        "n_steps": 14
      }
    ]
  }
)
