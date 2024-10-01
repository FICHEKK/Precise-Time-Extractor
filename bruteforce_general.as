// How to use:
// 1. Convert all of your replay .Gbx files to TMI input files.
// 2. Rename all of your TMI input files so they have the same name, but have increasing number suffix ("track0.txt", "track1.txt", "track2.txt"...).
// 3. Enter name of the track should be extracted ("track").
// 4. Enter from which index to which index to extract from (if min index = 0 and max index = 2, extract will be done for "track0.txt", "track1.txt" and "track2.txt").

Manager @m_Manager;

bool m_wasBaseRunFound = false;
int m_bestTime;
int m_bestTimeEver;
string m_resultFileName;
int currentReplayIndex = 0;

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

        PreciseTime::isEstimating = false;
        PreciseTime::coeffMin = 0;
        PreciseTime::coeffMax = 18446744073709551615;

        double foundPreciseTime = (simManager.RaceTime / 1000.0) + (currentCoeffPercentage / 100.0);
        double previousBestPreciseTime = PreciseTime::bestPreciseTime;
        double maxPreciseTimeLimit = previousBestPreciseTime;

        if (foundPreciseTime >= maxPreciseTimeLimit) {
            response.Decision = BFEvaluationDecision::Reject;
            return;
        }

        if (!m_wasBaseRunFound) {
            print("[Search phase] Found new base run with precise time: " +  DecimalFormatted(foundPreciseTime, 16) + " sec", Severity::Success);
            m_wasBaseRunFound = true;
        } else {
            print("[AS] Found precise time: " + DecimalFormatted(foundPreciseTime, 16), Severity::Success);
        }

        PreciseTime::bestPreciseTime = foundPreciseTime;
        m_bestTime = int(Math::Floor(PreciseTime::bestPreciseTime * 100.0)) * 10;
        
        if (PreciseTime::bestPreciseTime < PreciseTime::bestPreciseTimeEver) {
            PreciseTime::bestPreciseTimeEver = PreciseTime::bestPreciseTime;
            m_Manager.m_bfController.SaveSolutionToFile();
        }
		
        if (m_bestTime < m_bestTimeEver) {
            m_bestTimeEver = m_bestTime;
        }

        m_Manager.m_simManager.SetSimulationTimeLimit(m_bestTime + 10010);
        response.Decision = BFEvaluationDecision::Accept;
    }
}

void UpdateSettings() {
    SimulationManager@ simManager = m_Manager.m_simManager;

    if (@simManager != null && m_Manager.m_bfController.active) {
        m_Manager.m_simManager.SetSimulationTimeLimit(m_bestTime + 10010);
    }
}

class BruteforceController {
    BruteforceController() {}
    ~BruteforceController() {}

    void SetBruteforceVariables(SimulationManager@ simManager) {
        m_wasBaseRunFound = false;
        m_bestTime = simManager.EventsDuration;
        m_bestTimeEver = m_bestTime;

        PreciseTime::isEstimating = false;
        PreciseTime::coeffMin = 0;
        PreciseTime::coeffMax = 18446744073709551615;
        PreciseTime::bestPreciseTime = double(m_bestTime + 10) / 1000.0;
        PreciseTime::bestPreciseTimeEver = PreciseTime::bestPreciseTime;

        m_resultFileName = GetVariableString("fic_pte_file_name");
    }
    
    void StartInitialPhase() {
        m_phase = BFPhase::Initial;
        m_simManager.RewindToState(m_originalSimulationStates[m_rewindIndex]);
        m_originalSimulationStates.Resize(m_rewindIndex + 1);
    }

    void StartSearchPhase() {
        m_phase = BFPhase::Search;

        RandomNeighbour();
        m_simManager.RewindToState(m_originalSimulationStates[m_rewindIndex]);
    }

    void StartNewIteration() {
        RandomNeighbour();
        m_simManager.RewindToState(m_originalSimulationStates[m_rewindIndex]);
    }

    void OnSimulationBegin(SimulationManager@ simManager) {
        active = GetVariableString("controller") == "fic_pte";
        if (!active) return;

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
        if (!active) return;
        
        print("[AS] Bruteforce finished");
        active = false;

        m_originalInputEvents.Clear();
        m_originalSimulationStates.Clear();
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
        if (!active) return;

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
			m_commandList.Content = "# Found precise time: " + DecimalFormatted(PreciseTime::bestPreciseTime, 16) + "\n";
			m_commandList.Content += m_Manager.m_simManager.InputEvents.ToCommandsText(InputFormatFlags(3));
			m_commandList.Save(m_resultFileName);
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

    UI::PushItemWidth(150);
    if (!m_Manager.m_bfController.active) {
        m_resultFileName = UI::InputTextVar("File name", "fic_pte_file_name");
    } else {
        UI::Text("File name " + m_resultFileName);
    }
    UI::PopItemWidth();
}


void Main() {
    @m_Manager = Manager();
    RegisterVariable("fic_pte_file_name", "track");
    UpdateSettings();
    RegisterValidationHandler("fic_pte", "fic's Precise Time Extractor", BruteforceSettingsWindow);
}

PluginInfo@ GetPluginInfo() {
    auto info = PluginInfo();
    info.Name = "fic's Precise Time Extractor";
    info.Author = "fic";
    info.Version = "v1.0.0";
    info.Description = "Plugin that allows you to automatically extract precise times of multiple replay input files.";
    return info;
}
