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
		if (!simManager.PlayerInfo.RaceFinished) {
			response.Decision = BFEvaluationDecision::DoNothing;
			return;
		}

        if (!m_wasBaseRunFound) {
			print("[Initial phase] Found new base run with time: " +  (simManager.TickTime-10) + " sec", Severity::Success);
			m_wasBaseRunFound = true;
			m_bestTime = simManager.TickTime - 10;
			PreciseTime::bestPreciseTime = (m_bestTime / 1000.0) + 0.01;
			
			if (m_bestTime < m_bestTimeEver) {
				m_bestTimeEver = m_bestTime;
			}
		}

		response.Decision = BFEvaluationDecision::Accept;
    }

    void HandleSearchPhase(SimulationManager@ simManager, BFEvaluationResponse&out response, const BFEvaluationInfo&in info) {
        if (PreciseTime::isEstimating) {
			if (simManager.PlayerInfo.RaceFinished) {
                PreciseTime::coeffMax = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
            } else {
                PreciseTime::coeffMin = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
            }
        } else {
            if (simManager.PlayerInfo.RaceFinished) {
				PreciseTime::isEstimating = true;
            } else {
                @PreciseTime::originalStateBeforeTargetHit = simManager.SaveState();
                response.Decision = BFEvaluationDecision::DoNothing;
                return;
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
		
		if (m_wasBaseRunFound) {
			print("[Search phase] Found precise time: " + DecimalFormatted(foundPreciseTime, 16), Severity::Success);
        } else {
            print("[Search phase] Found new base run with precise time: " +  DecimalFormatted(foundPreciseTime, 16) + " sec", Severity::Success);
            m_wasBaseRunFound = true;
        }

        if (foundPreciseTime < PreciseTime::bestPreciseTime) {
            PreciseTime::bestPreciseTime = foundPreciseTime;
			
			if (PreciseTime::bestPreciseTime < PreciseTime::bestPreciseTimeEver) {
				PreciseTime::bestPreciseTimeEver = PreciseTime::bestPreciseTime;
			}
			
			m_bestTime = int(Math::Floor(PreciseTime::bestPreciseTime * 100.0)) * 10;
			
			if (m_bestTime < m_bestTimeEver) {
				m_bestTimeEver = m_bestTime;
			}
        }

		m_Manager.m_bfController.SaveSolutionToFile();
        m_Manager.m_simManager.SetSimulationTimeLimit(m_bestTime + 10010);
        response.Decision = BFEvaluationDecision::Accept;
    }
}

class BruteforceController {
    SimulationManager@ m_simManager;
    bool active = false;
    BFPhase m_phase = BFPhase::Initial;

    void OnSimulationBegin(SimulationManager@ simManager) {
        active = GetVariableString("controller") == "fic_pte";
        if (!active) return;

        print("[AS] Starting bruteforce...");

        @m_simManager = simManager;
        m_simManager.InputEvents.RemoveAt(m_simManager.InputEvents.Length - 1);
		m_simManager.SetSimulationTimeLimit(simManager.EventsDuration + 10010);
       
		m_wasBaseRunFound = false;
        m_bestTime = simManager.EventsDuration;
        m_bestTimeEver = m_bestTime;
		m_phase = BFPhase::Initial;
		m_resultFileName = GetVariableString("fic_pte_file_name");

        PreciseTime::isEstimating = false;
        PreciseTime::coeffMin = 0;
        PreciseTime::coeffMax = 18446744073709551615;
        PreciseTime::bestPreciseTime = double(m_bestTime + 10) / 1000.0;
        PreciseTime::bestPreciseTimeEver = PreciseTime::bestPreciseTime;
    }

    void OnSimulationStep(SimulationManager@ simManager) {
        if (!active) return;

        BFEvaluationInfo info;
        info.Phase = m_phase;
		BFEvaluationResponse response;

        switch(info.Phase) {
            case BFPhase::Initial:
                PreciseTime::HandleInitialPhase(m_simManager, response, info);
                break;
            case BFPhase::Search:
                PreciseTime::HandleSearchPhase(m_simManager, response, info);
                break;
        }

        switch(response.Decision) {
            case BFEvaluationDecision::DoNothing:
                break;
				
            case BFEvaluationDecision::Accept:
                if (m_phase == BFPhase::Initial) {
                    m_phase = BFPhase::Search;
                    break;
                }

                m_phase = BFPhase::Initial;
                break;
            case BFEvaluationDecision::Reject:
                if (m_phase == BFPhase::Initial) {
                    print("[AS] Cannot reject in initial phase, ignoring");
                    break;
                }

                break;
            case BFEvaluationDecision::Stop:
                print("[AS] Stopped");
                OnSimulationEnd(simManager);
                break;
        }
    }

    void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target) {
        if (!active) return;

        if (m_simManager.PlayerInfo.RaceFinished) {
            m_simManager.PreventSimulationFinish();
        }
    }
	
	void OnSimulationEnd(SimulationManager@ simManager) {
        if (!active) return;
        
        print("[AS] Bruteforce finished");
        active = false;
        simManager.SetSimulationTimeLimit(0.0);
    }

    void SaveSolutionToFile() {
		CommandList commandList;
        commandList.Content = "# Found precise time: " + DecimalFormatted(PreciseTime::bestPreciseTime, 16) + "\n";
		commandList.Content += m_Manager.m_simManager.InputEvents.ToCommandsText(InputFormatFlags(3));
		commandList.Save(m_resultFileName);
    }
}

class Manager {
    SimulationManager@ m_simManager;
    BruteforceController@ m_bfController;
	
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
}

void OnSimulationBegin(SimulationManager@ simManager) {
    m_Manager.OnSimulationBegin(simManager);
}

void OnSimulationStep(SimulationManager@ simManager, bool userCancelled) {
    m_Manager.OnSimulationStep(simManager, userCancelled);
}

void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target) {
    m_Manager.OnCheckpointCountChanged(simManager, count, target);
}

void OnSimulationEnd(SimulationManager@ simManager, uint result) {
    m_Manager.OnSimulationEnd(simManager, result);
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
