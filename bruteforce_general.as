// How to use:
// 1. Convert all of your replay .Gbx files to TMI input files.
// 2. Rename all of your TMI input files so they have the same name, but have increasing number suffix ("track1.txt", "track2.txt", "track3.txt"...).
// 3. Enter name of the track should be extracted ("track").
// 4. Enter from which index to which index to extract from (if min index = 1 and max index = 3, extract will be done for "track1.txt", "track2.txt" and "track3.txt").

const int MIN_REPLAY_INDEX = 1;
const int MAX_REPLAY_INDEX = 4;

bool m_active = false;
SimulationState@ m_startState;
BFPhase m_phase = BFPhase::Initial;

int m_currentReplayIndex = 1;
int m_bestPreciseTimeIndex;
string m_resultFileName;

namespace PreciseTime
{
    double lastFound;
    double bestFound;
    
    bool isEstimating = false;
    uint64 coeffMin = 0;
    uint64 coeffMax = 18446744073709551615; 
    SimulationState@ stateBeforeFinishing;

    void HandleInitialPhase(SimulationManager@ simManager, BFEvaluationResponse&out response, const BFEvaluationInfo&in info)
    {
        if (simManager.PlayerInfo.RaceFinished)
        {
            response.Decision = BFEvaluationDecision::Accept;
            return;
        }

        @PreciseTime::stateBeforeFinishing = simManager.SaveState();
        response.Decision = BFEvaluationDecision::DoNothing;
    }

    void HandleSearchPhase(SimulationManager@ simManager, BFEvaluationResponse&out response, const BFEvaluationInfo&in info)
    {
        if (PreciseTime::isEstimating)
        {
            if (simManager.PlayerInfo.RaceFinished)
            {
                PreciseTime::coeffMax = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
            }
            else
            {
                PreciseTime::coeffMin = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
            }
        }
        else
        {
            if (simManager.PlayerInfo.RaceFinished)
            {
                PreciseTime::isEstimating = true;
            }
            else
            {
                response.Decision = BFEvaluationDecision::DoNothing;
                return;
            }
        }

        simManager.RewindToState(PreciseTime::stateBeforeFinishing);
        uint64 currentCoeff = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
        double currentCoeffPercentage = currentCoeff / 18446744073709551615.0;

        if (PreciseTime::coeffMax - PreciseTime::coeffMin > 1)
        {
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
        PreciseTime::lastFound = (simManager.RaceTime / 1000.0) + (currentCoeffPercentage / 100.0);
        if (PreciseTime::lastFound < PreciseTime::bestFound) PreciseTime::bestFound = PreciseTime::lastFound;

        response.Decision = BFEvaluationDecision::Accept;
    }
}

void OnSimulationBegin(SimulationManager@ simManager)
{
    m_active = GetVariableString("controller") == "fic_pte";
    if (!m_active) return;
        
    simManager.RemoveStateValidation();
    simManager.InputEvents.RemoveAt(simManager.InputEvents.Length - 1);

    m_phase = BFPhase::Initial;
    m_resultFileName = GetVariableString("fic_pte_file_name");
    m_currentReplayIndex = 1;

    PreciseTime::isEstimating = false;
    PreciseTime::coeffMin = 0;
    PreciseTime::coeffMax = 18446744073709551615;
    PreciseTime::bestFound = Math::UINT64_MAX;
    
    int totalInputFiles = MAX_REPLAY_INDEX - MIN_REPLAY_INDEX + 1;
    Log("Starting precise time extraction for " + totalInputFiles + " input files: " + m_resultFileName + MIN_REPLAY_INDEX + ", ... , " + m_resultFileName + MAX_REPLAY_INDEX);
    LoadInputsForReplayWithIndex(m_currentReplayIndex, simManager);
}

void OnSimulationStep(SimulationManager@ simManager, bool userCancelled)
{
    if (!m_active || userCancelled)
    {
        OnSimulationEnd(simManager, 0);
        return;
    }
    
    if (simManager.TickTime == 0) @m_startState = simManager.SaveState();

    BFEvaluationInfo info;
    info.Phase = m_phase;
    BFEvaluationResponse response;
    
    if (info.Phase == BFPhase::Initial)
    {
        PreciseTime::HandleInitialPhase(simManager, response, info);
    }
    else
    {
        PreciseTime::HandleSearchPhase(simManager, response, info);
    }
    
    if (response.Decision != BFEvaluationDecision::Accept) return;
    
    if (m_phase == BFPhase::Initial)
    {
        m_phase = BFPhase::Search;
        return;
    }

    SaveInputsToFile(simManager, PreciseTime::lastFound);
    if (PreciseTime::lastFound == PreciseTime::bestFound) m_bestPreciseTimeIndex = m_currentReplayIndex;
    
    m_phase = BFPhase::Initial;
    m_currentReplayIndex++;
    
    if (m_currentReplayIndex > MAX_REPLAY_INDEX)
    {
        Log("All replays have been processed! Best replay was \"" + m_resultFileName + "" + m_bestPreciseTimeIndex + "\" with time of " + FormatDouble(PreciseTime::bestFound) + ".");
        OnSimulationEnd(simManager, 0);
        return;
    }
    
    LoadInputsForReplayWithIndex(m_currentReplayIndex, simManager);
    simManager.RewindToState(m_startState);
}

void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target)
{
    if (!m_active) return;
    if (simManager.PlayerInfo.RaceFinished) simManager.PreventSimulationFinish();
}

void OnSimulationEnd(SimulationManager@ simManager, uint result)
{
    if (!m_active) return;
    
    m_active = false;
    simManager.SetSimulationTimeLimit(0.0);
}

void SaveInputsToFile(SimulationManager@ simManager, double foundPreciseTime)
{
    CommandList commandList;
    string preciseTime = FormatDouble(foundPreciseTime);
    
    commandList.Content = "# Found precise time: " + preciseTime + "\n";
    commandList.Content += simManager.InputEvents.ToCommandsText(InputFormatFlags(3));
    commandList.Save(m_resultFileName + "_" + preciseTime + "_" + m_currentReplayIndex + ".txt");
    
    Log("Saved precise time for input file \"" + m_resultFileName + "" + m_currentReplayIndex + "\": " + preciseTime, Severity::Success);
}

void LoadInputsForReplayWithIndex(int index, SimulationManager@ simManager)
{
    CommandList commandList(m_resultFileName + m_currentReplayIndex + ".txt");
    commandList.Process(CommandListProcessOption::ExecuteImmediately);
    SetCurrentCommandList(commandList);
    simManager.InputEvents.Clear();
    
    for (uint i = 0; i < commandList.InputCommands.Length; i++)
    {
        InputCommand event = commandList.InputCommands[i];
        simManager.InputEvents.Add(event.Timestamp, event.Type, event.State);
    }
}

void Log(string message, Severity severity = Severity :: Info)
{
    const string prefix = "[PTE]";
    print(prefix + " " + message, severity);
}

string FormatDouble(double value)
{
    const int precision = 16;
    return Text::FormatFloat(value, "", 0, precision);
}

void RenderSettings()
{
    UI::Dummy(vec2(0, 15));

    UI::TextDimmed("Options:");

    UI::Dummy(vec2(0, 15));
    UI::Separator();
    UI::Dummy(vec2(0, 15));

    UI::PushItemWidth(150);
    if (!m_active)
    {
        m_resultFileName = UI::InputTextVar("File name", "fic_pte_file_name");
    }
    else
    {
        UI::Text("File name " + m_resultFileName);
    }
    UI::PopItemWidth();
}

void Main()
{
    RegisterVariable("fic_pte_file_name", "track");
    RegisterValidationHandler("fic_pte", "fic's Precise Time Extractor", RenderSettings);
}

PluginInfo@ GetPluginInfo()
{
    auto info = PluginInfo();
    info.Name = "fic's Precise Time Extractor";
    info.Author = "fic";
    info.Version = "v1.0.0";
    info.Description = "Plugin that allows you to automatically extract precise times of multiple replay input files.";
    return info;
}
