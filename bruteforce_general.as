Manager @m_Manager;

// bruteforce vars
int m_bestTime; // best time the bf found so far, precise or not

// helper vars
bool m_wasBaseRunFound = false;
int m_bestTimeEver; // keeps track for the best time ever reached, useful for bf that allows for worse times to be found
bool m_canAcceptWorseTimes = false; // will become true if settings are set that allow for worse times to be found


// settings vars
string m_resultFileName;

bool m_useInfoLogging;
bool m_useIterLogging;
uint m_loggingInterval;

// info vars
uint m_iterations = 0; // total iterations
uint m_iterationsCounter = 0; // iterations counter, used to update the iterations per second
float m_iterationsPerSecond = 0.0f; // iterations per second
float m_lastIterationsPerSecondUpdate = 0.0f; // last time the iterations per second were updated

string DecimalFormatted(float number, int precision = 10) {
    return Text::FormatFloat(number, "{0:10f}", 0, precision);
}

string DecimalFormatted(double number, int precision = 10) {
    return Text::FormatFloat(number, "{0:10f}", 0, precision);
}

namespace PreciseTime {
    double bestPreciseTime; // best precise time the bf found so far
    double bestPreciseTimeEver; // keeps track for the best precise time ever reached, useful for bf that allows for worse times to be found
    bool isEstimating = false;
    uint64 coeffMin = 0;
    uint64 coeffMax = 18446744073709551615; 
    SimulationState@ originalStateBeforeTargetHit;

    void HandleInitialPhase(SimulationManager@ simManager, BFEvaluationResponse&out response, const BFEvaluationInfo&in info) {
        int tickTime = simManager.TickTime;

        bool targetReached = simManager.PlayerInfo.RaceFinished;
        int maxTimeLimit = m_bestTime;

        if (targetReached) {
            if (!m_wasBaseRunFound) {
                print("[Initial phase] Found new base run with time: " +  (tickTime-10) + " sec", Severity::Success);
                m_wasBaseRunFound = true;
                m_bestTime = tickTime - 10;
                PreciseTime::bestPreciseTime = (m_bestTime / 1000.0) + 0.01;
                
                // check if best time ever was driven
                if (m_bestTime < m_bestTimeEver) {
                    m_bestTimeEver = m_bestTime;
                    m_Manager.m_bfController.SaveSolutionToFile();
                }
            }

            response.Decision = BFEvaluationDecision::Accept;
            return;
        }

        if (tickTime > maxTimeLimit) {
            if (!m_wasBaseRunFound) {
                print("[Initial phase] Base run did not reach target, starting search for a base run..", Severity::Info);
            } else {
                // initial usually can only not reach the target once, and future initial phases will hit it, however i decided that if one were to change
                // the position of the trigger during bruteforce, the target may not be reached anymore in initial phase, so we will allow the bruteforce
                // to find yet another base run again
                print("[Initial phase] Base run could not reach the target anymore, despite previously having reached it. Some bruteforcing condition must have changed. Starting search for a base run..", Severity::Info);
                m_wasBaseRunFound = false;
            }
            
            response.Decision = BFEvaluationDecision::Accept;
            return;
        }

        response.Decision = BFEvaluationDecision::DoNothing;
    }

    void HandleSearchPhase(SimulationManager@ simManager, BFEvaluationResponse&out response, const BFEvaluationInfo&in info) {
        int tickTime = simManager.TickTime;

        bool targetReached = simManager.PlayerInfo.RaceFinished;

        // see previous usages of this variable for more info
        int maxTimeLimit = m_bestTime;

        if (!PreciseTime::isEstimating) {
            if (!targetReached) {
                if (tickTime > maxTimeLimit) {
                    response.Decision = BFEvaluationDecision::Reject;
                    return;
                }

                @PreciseTime::originalStateBeforeTargetHit = simManager.SaveState();
                response.Decision = BFEvaluationDecision::DoNothing;
                return;
            } else {
                PreciseTime::isEstimating = true;
            }
        } else {
            if (targetReached) {
                PreciseTime::coeffMax = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
            } else {
                PreciseTime::coeffMin = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
            }
        }

        simManager.RewindToState(PreciseTime::originalStateBeforeTargetHit);
        
        uint64 currentCoeff = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
        double currentCoeffPercentage = currentCoeff / 18446744073709551615.0;

        if (PreciseTime::coeffMax - PreciseTime::coeffMin > 1) {
            vec3 LinearSpeed = simManager.Dyna.CurrentState.LinearSpeed;
            vec3 AngularSpeed = simManager.Dyna.CurrentState.AngularSpeed;
            LinearSpeed *= currentCoeffPercentage;
            AngularSpeed *= currentCoeffPercentage;
            simManager.Dyna.CurrentState.LinearSpeed = LinearSpeed;
            simManager.Dyna.CurrentState.AngularSpeed = AngularSpeed;
            response.Decision = BFEvaluationDecision::DoNothing;
            return;
        }

        // finished estimating precise time
        PreciseTime::isEstimating = false;
        PreciseTime::coeffMin = 0;
        PreciseTime::coeffMax = 18446744073709551615;

        double foundPreciseTime = (simManager.RaceTime / 1000.0) + (currentCoeffPercentage / 100.0);
        double previousBestPreciseTime = PreciseTime::bestPreciseTime;

        // see previous usages of this variable for more info (maxTimeLimit)
        double maxPreciseTimeLimit = previousBestPreciseTime;

        if (foundPreciseTime >= maxPreciseTimeLimit) {
            response.Decision = BFEvaluationDecision::Reject;
            return;
        }

        // handle worse result acceptance probability
        if (m_canAcceptWorseTimes && foundPreciseTime > previousBestPreciseTime) {
            if (Math::Rand(0.0f, 1.0f) > 1) {
                response.Decision = BFEvaluationDecision::Reject;
                return;
            }
        }

        // anything below this point means we will accept the new time

        if (!m_wasBaseRunFound) {
            print("[Search phase] Found new base run with precise time: " +  DecimalFormatted(foundPreciseTime, 16) + " sec", Severity::Success);
            m_wasBaseRunFound = true;
        } else {
            string message = "[AS] Found";
            // higher or equal can only occur if settings are set up in such a way that worse (or equal) times are allowed to be found
            if (foundPreciseTime < previousBestPreciseTime) {
                message += " lower ";
            } else if (foundPreciseTime == previousBestPreciseTime) {
                message += " equal ";
            } else {
                message += " higher ";
            }
            message += "precise time: " + DecimalFormatted(foundPreciseTime, 16);
            print(message, Severity::Success);
        }

        PreciseTime::bestPreciseTime = foundPreciseTime;
        m_bestTime = int(Math::Floor(PreciseTime::bestPreciseTime * 100.0)) * 10;
            
        // check if best time ever was driven
        if (PreciseTime::bestPreciseTime < PreciseTime::bestPreciseTimeEver) {
            PreciseTime::bestPreciseTimeEver = PreciseTime::bestPreciseTime;
            m_Manager.m_bfController.SaveSolutionToFile();
        }
        if (m_bestTime < m_bestTimeEver) {
            m_bestTimeEver = m_bestTime;
        }

        m_Manager.m_simManager.SetSimulationTimeLimit(m_bestTime + 10010); // i add 10010 because tmi subtracts 10010 and it seems to be wrong. (also dont confuse this with the other value of 100010, thats something else)

        response.Decision = BFEvaluationDecision::Accept;
    }
}

// general settings that can be updated during our outside of bruteforce and can be called at any point in time
void UpdateSettings() {
    SimulationManager@ simManager = m_Manager.m_simManager;

    if (@simManager != null && m_Manager.m_bfController.active) {
        m_Manager.m_simManager.SetSimulationTimeLimit(m_bestTime + 10010); // i add 10010 because tmi subtracts 10010 and it seems to be wrong. (also dont confuse this with the other value of 100010, thats something else)
    }

    // logging
    m_useInfoLogging = GetVariableBool("kim_bf_use_info_logging");
    m_useIterLogging = GetVariableBool("kim_bf_use_iter_logging");
    m_loggingInterval = Math::Clamp(uint(GetVariableDouble("kim_bf_logging_interval")), 1, 1000);

    // specify any conditions that could lead to a worse time here
    m_canAcceptWorseTimes = false;
}

/* SIMULATION MANAGEMENT */

class BruteforceController {
    BruteforceController() {}
    ~BruteforceController() {}

    // reset variables bruteforce needs
    void SetBruteforceVariables(SimulationManager@ simManager) {
        // General Variables
        m_wasBaseRunFound = false;
        m_bestTime = simManager.EventsDuration; // original time of the replay
        m_bestTimeEver = m_bestTime;

        m_iterations = 0;
        m_iterationsCounter = 0;
        m_iterationsPerSecond = 0.0f;
        m_lastIterationsPerSecondUpdate = 0.0f;

        // PreciseTime Variables
        PreciseTime::isEstimating = false;
        PreciseTime::coeffMin = 0;
        PreciseTime::coeffMax = 18446744073709551615;
        PreciseTime::bestPreciseTime = double(m_bestTime + 10) / 1000.0; // best precise time the bf found so far
        // PreciseTime helper variables
        PreciseTime::bestPreciseTimeEver = PreciseTime::bestPreciseTime;

        // Bruteforce Variables
        m_resultFileName = GetVariableString("kim_bf_result_file_name");
    }
    
    void StartInitialPhase() {
        UpdateIterationsPerSecond(); // it aint really an iteration, but it kinda wont update the performance of the simulation if you happen to have a lot of initial phases

        m_phase = BFPhase::Initial;
        m_simManager.RewindToState(m_originalSimulationStates[m_rewindIndex]);
        m_originalSimulationStates.Resize(m_rewindIndex + 1);
    }

    void StartSearchPhase() {
        UpdateIterationsPerSecond();

        m_phase = BFPhase::Search;

        RandomNeighbour();
        m_simManager.RewindToState(m_originalSimulationStates[m_rewindIndex]);
    }

    void StartNewIteration() {
        UpdateIterationsPerSecond();

        // randomize the inputbuffers values
        RandomNeighbour();
        m_simManager.RewindToState(m_originalSimulationStates[m_rewindIndex]);
    }

    void OnSimulationBegin(SimulationManager@ simManager) {
        active = GetVariableString("controller") == "kim_bf_controller";
        if (!active) {
            return;
        }

        print("[AS] Starting bruteforce..");

        @m_simManager = simManager;

        // knock off finish event from the input buffer
        m_simManager.InputEvents.RemoveAt(m_simManager.InputEvents.Length - 1);
        
        // handle variables 
        SetBruteforceVariables(simManager);
        UpdateSettings();

        m_phase = BFPhase::Initial;
        m_originalSimulationStates = array<SimulationState@>();
        m_originalInputEvents.Clear();
        m_originalSimulationStates.Clear();
    }

    void OnSimulationEnd(SimulationManager@ simManager) {
        if (!active) {
            return;
        }
        print("[AS] Bruteforce finished");
        active = false;

        m_originalInputEvents.Clear();
        m_originalSimulationStates.Clear();


        // set the simulation time limit to make the game quit the simulation right away, or else we'll have to wait all the way until the end of the replay..
        simManager.SetSimulationTimeLimit(0.0);
    }

    void PrintInputBuffer() {
        // somehow this doesnt show steering events properly after i filled in the missing inputs, but it does work for acceleration and brake
        print(m_simManager.InputEvents.ToCommandsText(InputFormatFlags(3)));
    }

    void RandomNeighbour() {
        TM::InputEventBuffer@ inputBuffer = m_simManager.InputEvents;

        m_rewindIndex = 2147483647;
        uint lowestTimeModified = 2147483647;

        // copy inputBuffer into m_originalInputEvents
        m_originalInputEvents.Clear();
        for (uint i = 0; i < inputBuffer.Length; i++) {
            m_originalInputEvents.Add(inputBuffer[i]);
        }

        if (lowestTimeModified == 0 || lowestTimeModified == 2147483647) {
            m_rewindIndex = 0;
        } else {
            m_rewindIndex = lowestTimeModified / 10 - 1;
        }

        if (m_originalSimulationStates[m_originalSimulationStates.Length-1].PlayerInfo.RaceTime < int(m_rewindIndex * 10)) {
            print("[AS] Rewind time is higher than highest saved simulation state, this can happen when custom stop time delta is > 0.0 and inputs were generated that occurred beyond the finish time that was driven during the initial phase. RandomNeighbour will be called again. If this keeps happening, lower the custom stop time.", Severity::Warning);
            RandomNeighbour();
        }

    }

    void OnSimulationStep(SimulationManager@ simManager) {
        if (!active) {
            return;
        }

        BFEvaluationInfo info;
        info.Phase = m_phase;
        
        BFEvaluationResponse evalResponse = OnBruteforceStep(simManager, info);

        switch(evalResponse.Decision) {
            case BFEvaluationDecision::DoNothing:
                if (m_phase == BFPhase::Initial) {
                    CollectInitialPhaseData(simManager);
                }
                break;
            case BFEvaluationDecision::Accept:
                if (m_phase == BFPhase::Initial) {
                    StartSearchPhase();
                    break;
                }

                m_originalInputEvents.Clear();
                StartInitialPhase();
                break;
            case BFEvaluationDecision::Reject:
                if (m_phase == BFPhase::Initial) {
                    print("[AS] Cannot reject in initial phase, ignoring");
                    break;
                }

                RestoreInputBuffer();
                StartNewIteration();
                break;
            case BFEvaluationDecision::Stop:
                print("[AS] Stopped");
                OnSimulationEnd(simManager);
                break;
        }
    }

    void RestoreInputBuffer() {
        m_simManager.InputEvents.Clear();
        for (uint i = 0; i < m_originalInputEvents.Length; i++) {
            m_simManager.InputEvents.Add(m_originalInputEvents[i]);
        }
        m_originalInputEvents.Clear();
    }

    void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target) {
        if (!active) {
            return;
        }

        if (m_simManager.PlayerInfo.RaceFinished) {
            m_simManager.PreventSimulationFinish();
        }
    }

    void CollectInitialPhaseData(SimulationManager@ simManager) {
        if (simManager.RaceTime >= 0) {
            m_originalSimulationStates.Add(m_simManager.SaveState());
        }
    }

    void HandleSearchPhase(SimulationManager@ simManager, BFEvaluationResponse&out response, BFEvaluationInfo&in info) {
        PreciseTime::HandleSearchPhase(m_simManager, response, info);
    }

    void HandleInitialPhase(SimulationManager@ simManager, BFEvaluationResponse&out response, BFEvaluationInfo&in info) {
        PreciseTime::HandleInitialPhase(m_simManager, response, info);
    }

    BFEvaluationResponse@ OnBruteforceStep(SimulationManager@ simManager, const BFEvaluationInfo&in info) {
        BFEvaluationResponse response;

        switch(info.Phase) {
            case BFPhase::Initial:
                HandleInitialPhase(simManager, response, info);
                break;
            case BFPhase::Search:
                HandleSearchPhase(simManager, response, info);
                break;
        }

        return response;
    }

    void SaveSolutionToFile() {
        // m_commandList.Content = simManager.InputEvents.ToCommandsText();
        // only save if the time we found is the best time ever, currently also saves when an equal time was found and accepted
        if (PreciseTime::bestPreciseTime == PreciseTime::bestPreciseTimeEver) {
			m_commandList.Content = "# Found precise time: " + DecimalFormatted(PreciseTime::bestPreciseTime, 16) + ", iterations: " + m_iterations + "\n";
			m_commandList.Content += m_Manager.m_simManager.InputEvents.ToCommandsText(InputFormatFlags(3));
			m_commandList.Save(m_resultFileName);
		}
    }

    // informational functions
    void PrintBruteforceInfo() {
        if (!m_useInfoLogging && !m_useIterLogging) {
            return;
        }
        
        string message = "[AS] ";

        if (m_useInfoLogging) {
            message += "best precise time: " + DecimalFormatted(PreciseTime::bestPreciseTime, 16);
        }

        if (m_useIterLogging) {
            if (m_useInfoLogging) {
                message += " | ";
            }
            message += "iterations: " + Text::FormatInt(m_iterations) + " | iters/sec: " + DecimalFormatted(m_iterationsPerSecond, 2);
        }

        print(message);
    }

    void UpdateIterationsPerSecond() {
        m_iterations++;
        m_iterationsCounter++;

        if (m_iterationsCounter % m_loggingInterval == 0) {
            PrintBruteforceInfo();

            float currentTime = float(Time::Now);
            currentTime /= 1000.0f;
            float timeSinceLastUpdate = currentTime - m_lastIterationsPerSecondUpdate;
            m_iterationsPerSecond = float(m_iterationsCounter) / timeSinceLastUpdate;
            m_lastIterationsPerSecondUpdate = currentTime;
            m_iterationsCounter = 0;
        }
    }

    SimulationManager@ m_simManager;
    CommandList m_commandList;
    bool active = false;
    BFPhase m_phase = BFPhase::Initial;

    array<SimulationState@> m_originalSimulationStates = {};
    array<TM::InputEvent> m_originalInputEvents; 

    private uint m_rewindIndex = 0;
}

class Manager {
    Manager() {
        @m_bfController = BruteforceController();
    }
    ~Manager() {}

    void OnSimulationBegin(SimulationManager@ simManager) {
        @m_simManager = simManager;
        m_simManager.RemoveStateValidation();
        m_bfController.OnSimulationBegin(simManager);
    }

    void OnSimulationStep(SimulationManager@ simManager, bool userCancelled) {
        if (userCancelled) {
            m_bfController.OnSimulationEnd(simManager);
            return;
        }

        m_bfController.OnSimulationStep(simManager);
    }

    void OnSimulationEnd(SimulationManager@ simManager, uint result) {
        m_bfController.OnSimulationEnd(simManager);
    }

    void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target) {
        m_bfController.OnCheckpointCountChanged(simManager, count, target);
    }

    SimulationManager@ m_simManager;
    BruteforceController@ m_bfController;
}

/* these functions are called from the game, we relay them to our manager */
void OnSimulationBegin(SimulationManager@ simManager) {
    m_Manager.OnSimulationBegin(simManager);
}

void OnSimulationEnd(SimulationManager@ simManager, uint result) {
    m_Manager.OnSimulationEnd(simManager, result);
}

void OnSimulationStep(SimulationManager@ simManager, bool userCancelled) {
    m_Manager.OnSimulationStep(simManager, userCancelled);
}

void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target) {
    m_Manager.OnCheckpointCountChanged(simManager, count, target);
}

void BruteforceSettingsWindow() {
    UI::Dummy(vec2(0, 15));

    UI::TextDimmed("Options:");

    UI::Dummy(vec2(0, 15));
    UI::Separator();
    UI::Dummy(vec2(0, 15));

    // m_resultFileName
    UI::PushItemWidth(120);
    if (!m_Manager.m_bfController.active) {
        m_resultFileName = UI::InputTextVar("Result file name", "kim_bf_result_file_name");
    } else {
        UI::Text("Result file name " + m_resultFileName);
    }
    UI::PopItemWidth();

    UI::Dummy(vec2(0, 15));
    UI::Separator();
    UI::Dummy(vec2(0, 15));
    
    UI::PopItemWidth();

    // kim_bf_use_info_logging
    m_useInfoLogging = UI::CheckboxVar("Log Info", "kim_bf_use_info_logging");
    UI::TextDimmed("Log information about the current run to the console.");

    // kim_bf_use_iter_logging
    m_useIterLogging = UI::CheckboxVar("Log Iterations", "kim_bf_use_iter_logging");
    UI::TextDimmed("Log information about each iteration to the console.");

    // kim_bf_logging_interval
    UI::PushItemWidth(180);
    m_loggingInterval = uint(Math::Clamp(UI::SliderIntVar("Logging Interval", "kim_bf_logging_interval", 1, 1000), 1, 1000));
    SetVariable("kim_bf_logging_interval", m_loggingInterval);
    UI::TextDimmed("Log to console every x iterations.");
    UI::PopItemWidth();


    // specify any conditions that could lead to a worse time here
    m_canAcceptWorseTimes = false;
}


void Main() {
    @m_Manager = Manager();

    RegisterVariable("kim_bf_result_file_name", "result.txt");

    RegisterVariable("kim_bf_use_info_logging", true);
    RegisterVariable("kim_bf_use_iter_logging", true);
    RegisterVariable("kim_bf_logging_interval", 200.0);

    UpdateSettings();

    RegisterValidationHandler("kim_bf_controller", "[AS] Kim's Bruteforce Controller", BruteforceSettingsWindow);
}

PluginInfo@ GetPluginInfo() {
    auto info = PluginInfo();
    info.Name = "Kim's Bruteforce Controller";
    info.Author = "Kim";
    info.Version = "v1.3.4";
    info.Description = "General bruteforcing capabilities";
    return info;
}
