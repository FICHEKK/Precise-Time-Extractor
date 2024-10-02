// How to use:
// 1. Convert all of your replay .Gbx files to TMI input files.
// 2. Rename all of your TMI input files so they have the same name, but have increasing number suffix ("track1.txt", "track2.txt", "track3.txt"...).
// 3. Enter name of the track should be extracted ("track").
// 4. Enter from which index to which index to extract from (if min index = 1 and max index = 3, extract will be done for "track1.txt", "track2.txt" and "track3.txt").

BruteforceController@ m_bfController;
bool m_wasBaseRunFound = false;
int m_bestTime;
int m_bestTimeEver;
string m_resultFileName;
int m_currentReplayIndex = 1;

const int MIN_REPLAY_INDEX = 1;
const int MAX_REPLAY_INDEX = 3;

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
		// print("initial + " + simManager.PlayerInfo.RaceFinished + " | " + simManager.TickTime + " | " + simManager.RaceTime);
		
		if (!simManager.PlayerInfo.RaceFinished) {
			//print("now saving " + m_currentReplayIndex);
			@PreciseTime::originalStateBeforeTargetHit = simManager.SaveState();
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
                response.Decision = BFEvaluationDecision::DoNothing;
                return;
            }
        }

        simManager.RewindToState(PreciseTime::originalStateBeforeTargetHit);
        uint64 currentCoeff = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
        double currentCoeffPercentage = currentCoeff / 18446744073709551615.0;

        if (PreciseTime::coeffMax - PreciseTime::coeffMin > 1) {
			//print("binary searching " + m_currentReplayIndex);
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

		SaveInputsToFile(simManager, foundPreciseTime);
        m_bfController.m_simManager.SetSimulationTimeLimit(m_bestTime + 10010);
		response.Decision = BFEvaluationDecision::Accept;
    }
}

class BruteforceController {
    SimulationManager@ m_simManager;
    bool active = false;
    BFPhase m_phase = BFPhase::Initial;
	SimulationState@ startState;

    void OnSimulationBegin(SimulationManager@ simManager) {
        active = GetVariableString("controller") == "fic_pte";
        if (!active) return;

        @m_simManager = simManager;
        m_simManager.InputEvents.RemoveAt(m_simManager.InputEvents.Length - 1);
		m_simManager.SetSimulationTimeLimit(simManager.EventsDuration + 10010);
		
       
		m_wasBaseRunFound = false;
        m_bestTime = simManager.EventsDuration;
        m_bestTimeEver = m_bestTime;
		m_phase = BFPhase::Initial;
		m_resultFileName = GetVariableString("fic_pte_file_name");
		m_currentReplayIndex = 1;

        PreciseTime::isEstimating = false;
        PreciseTime::coeffMin = 0;
        PreciseTime::coeffMax = 18446744073709551615;
        PreciseTime::bestPreciseTime = double(m_bestTime + 10) / 1000.0;
        PreciseTime::bestPreciseTimeEver = PreciseTime::bestPreciseTime;
		
		print("[PTE] Starting precise time extraction for input files " + m_resultFileName + MIN_REPLAY_INDEX + ", ... , " + m_resultFileName + MAX_REPLAY_INDEX);
		LoadInputsForReplayWithIndex(m_currentReplayIndex, simManager);
    }

    void OnSimulationStep(SimulationManager@ simManager) {
        if (!active) return;
		
		if (simManager.TickTime == 0) {
			@startState = simManager.SaveState();
		}

        BFEvaluationInfo info;
        info.Phase = m_phase;
		BFEvaluationResponse response;

        switch(info.Phase) {
            case BFPhase::Initial:
                PreciseTime::HandleInitialPhase(simManager, response, info);
                break;
            case BFPhase::Search:
                PreciseTime::HandleSearchPhase(simManager, response, info);
                break;
        }

        switch(response.Decision) {
            case BFEvaluationDecision::DoNothing:
                break;
				
            case BFEvaluationDecision::Accept:
                m_phase = m_phase == BFPhase::Initial ? BFPhase::Search : BFPhase::Initial;
				
				if (m_phase == BFPhase::Initial) {
					print("Replay with index " + m_currentReplayIndex + " finished! Loading next run...");
					m_currentReplayIndex++;
					
					if (m_currentReplayIndex > MAX_REPLAY_INDEX) {
						print("All replays have been processed!");
						OnSimulationEnd(simManager);
						break;
					}
					
					LoadInputsForReplayWithIndex(m_currentReplayIndex, simManager);
					simManager.RewindToState(startState);
				}
				
                break;
				
            case BFEvaluationDecision::Reject:
                if (m_phase == BFPhase::Initial) print("[AS] Cannot reject in initial phase, ignoring");
                break;
				
            case BFEvaluationDecision::Stop:
                OnSimulationEnd(simManager);
                break;
        }
    }

    void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target) {
        if (!active) return;

        if (simManager.PlayerInfo.RaceFinished) {
            simManager.PreventSimulationFinish();
        }
    }
	
	void OnSimulationEnd(SimulationManager@ simManager) {
        if (!active) return;
        
        active = false;
        simManager.SetSimulationTimeLimit(0.0);
    }
	

}

void OnSimulationBegin(SimulationManager@ simManager) {
	simManager.RemoveStateValidation();
	m_bfController.OnSimulationBegin(simManager);
}

void OnSimulationStep(SimulationManager@ simManager, bool userCancelled) {
	if (userCancelled) {
		m_bfController.OnSimulationEnd(simManager);
		return;
	}

	m_bfController.OnSimulationStep(simManager);
}

void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target) {
    m_bfController.OnCheckpointCountChanged(simManager, count, target);
}

void OnSimulationEnd(SimulationManager@ simManager, uint result) {
    m_bfController.OnSimulationEnd(simManager);
}

void SaveInputsToFile(SimulationManager@ simManager, double foundPreciseTime) {
	CommandList commandList;
	string preciseTime = DecimalFormatted(foundPreciseTime, 16);
	commandList.Content = "# Found precise time: " + preciseTime + "\n";
	commandList.Content += simManager.InputEvents.ToCommandsText(InputFormatFlags(3));
	commandList.Save(m_resultFileName + "_" + preciseTime + "_" + m_currentReplayIndex + ".txt");
}

void LoadInputsForReplayWithIndex(int index, SimulationManager@ simManager) {
	CommandList commandList(m_resultFileName + m_currentReplayIndex + ".txt");
	commandList.Process(CommandListProcessOption::ExecuteImmediately);
	SetCurrentCommandList(commandList);
	
	simManager.InputEvents.Clear();
	
	for (uint i = 0; i < commandList.InputCommands.Length; i++) {
		InputCommand event = commandList.InputCommands[i];
		simManager.InputEvents.Add(event.Timestamp, event.Type, event.State);
	}
}

void RenderSettings() {
    UI::Dummy(vec2(0, 15));

    UI::TextDimmed("Options:");

    UI::Dummy(vec2(0, 15));
    UI::Separator();
    UI::Dummy(vec2(0, 15));

    UI::PushItemWidth(150);
    if (!m_bfController.active) {
        m_resultFileName = UI::InputTextVar("File name", "fic_pte_file_name");
    } else {
        UI::Text("File name " + m_resultFileName);
    }
    UI::PopItemWidth();
}


void Main() {
    @m_bfController = BruteforceController();
    RegisterVariable("fic_pte_file_name", "track");
    RegisterValidationHandler("fic_pte", "fic's Precise Time Extractor", RenderSettings);
}

PluginInfo@ GetPluginInfo() {
    auto info = PluginInfo();
    info.Name = "fic's Precise Time Extractor";
    info.Author = "fic";
    info.Version = "v1.0.0";
    info.Description = "Plugin that allows you to automatically extract precise times of multiple replay input files.";
    return info;
}
