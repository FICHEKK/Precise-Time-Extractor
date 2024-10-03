// How to use:
// 1. Convert all of your replay .Gbx files to TMI input files.
// 2. Rename all of your TMI input files so they have the same name, but have increasing number suffix ("track1.txt", "track2.txt", "track3.txt"...).
// 3. Enter name of the track should be extracted ("track").
// 4. Enter from which index to which index to extract from (if min index = 1 and max index = 3, extract will be done for "track1.txt", "track2.txt" and "track3.txt").

const int MIN_REPLAY_INDEX = 1;
const int MAX_REPLAY_INDEX = 4;

bool _isPluginSelectedByUser = false;
SimulationState@ _stateAtRaceStart;
int _currentReplayIndex = 1;
int _bestReplayIndex;
string _resultFileName;

namespace PreciseTime
{
    double lastFound;
    double bestFound;
    
    BFPhase searchPhase = BFPhase::Initial;
    bool isEstimating = false;
    uint64 coeffMin = 0;
    uint64 coeffMax = 18446744073709551615; 
    SimulationState@ stateBeforeFinishing;
    
    bool Simulate(SimulationManager@ simManager)
    {
        BFEvaluationDecision decision = searchPhase == BFPhase::Initial
            ? PreciseTime::HandleInitialPhase(simManager)
            : PreciseTime::HandleSearchPhase(simManager);
            
        if (decision != BFEvaluationDecision::Accept) return false;
        
        PreciseTime::searchPhase = PreciseTime::searchPhase == BFPhase::Initial
            ? BFPhase::Search
            : BFPhase::Initial;
            
        return PreciseTime::searchPhase == BFPhase::Initial;
    }

    BFEvaluationDecision HandleInitialPhase(SimulationManager@ simManager)
    {
        if (simManager.PlayerInfo.RaceFinished) return BFEvaluationDecision::Accept;

        @PreciseTime::stateBeforeFinishing = simManager.SaveState();
        return BFEvaluationDecision::DoNothing;
    }

    BFEvaluationDecision HandleSearchPhase(SimulationManager@ simManager)
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
                return BFEvaluationDecision::DoNothing;
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
            return BFEvaluationDecision::DoNothing;
        }

        PreciseTime::isEstimating = false;
        PreciseTime::coeffMin = 0;
        PreciseTime::coeffMax = 18446744073709551615;
        PreciseTime::lastFound = (simManager.RaceTime / 1000.0) + (currentCoeffPercentage / 100.0);
        if (PreciseTime::lastFound < PreciseTime::bestFound) PreciseTime::bestFound = PreciseTime::lastFound;

        return BFEvaluationDecision::Accept;
    }
}

void OnSimulationBegin(SimulationManager@ simManager)
{
    _isPluginSelectedByUser = GetVariableString("controller") == "fic_pte";
    if (!_isPluginSelectedByUser) return;
        
    simManager.RemoveStateValidation();
    simManager.InputEvents.RemoveAt(simManager.InputEvents.Length - 1);

    _resultFileName = GetVariableString("fic_pte_file_name");
    _currentReplayIndex = 1;

    PreciseTime::searchPhase = BFPhase::Initial;
    PreciseTime::isEstimating = false;
    PreciseTime::coeffMin = 0;
    PreciseTime::coeffMax = 18446744073709551615;
    PreciseTime::bestFound = Math::UINT64_MAX;
    
    int totalInputFiles = MAX_REPLAY_INDEX - MIN_REPLAY_INDEX + 1;
    Log("Starting precise time extraction for " + totalInputFiles + " input files: " + _resultFileName + MIN_REPLAY_INDEX + ", ... , " + _resultFileName + MAX_REPLAY_INDEX);
    LoadInputsForReplayWithIndex(_currentReplayIndex, simManager);
}

void OnSimulationStep(SimulationManager@ simManager, bool userCancelled)
{
    if (!_isPluginSelectedByUser || userCancelled)
    {
        OnSimulationEnd(simManager, 0);
        return;
    }
    
    if (simManager.TickTime == 0) @_stateAtRaceStart = simManager.SaveState();

    bool finishedSimulatingCurrentReplay = PreciseTime::Simulate(simManager);
    if (!finishedSimulatingCurrentReplay) return;

    SaveInputsToFile(simManager, PreciseTime::lastFound);
    if (PreciseTime::lastFound == PreciseTime::bestFound) _bestReplayIndex = _currentReplayIndex;
    
    if (++_currentReplayIndex > MAX_REPLAY_INDEX)
    {
        Log("All replays have been processed! Best replay was \"" + _resultFileName + "" + _bestReplayIndex + "\" with time of " + FormatDouble(PreciseTime::bestFound) + ".");
        OnSimulationEnd(simManager, 0);
        return;
    }
    
    LoadInputsForReplayWithIndex(_currentReplayIndex, simManager);
    simManager.RewindToState(_stateAtRaceStart);
}

void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target)
{
    if (!_isPluginSelectedByUser) return;
    if (simManager.PlayerInfo.RaceFinished) simManager.PreventSimulationFinish();
}

void OnSimulationEnd(SimulationManager@ simManager, uint result)
{
    if (!_isPluginSelectedByUser) return;
    
    _isPluginSelectedByUser = false;
    simManager.SetSimulationTimeLimit(0.0);
}

void SaveInputsToFile(SimulationManager@ simManager, double foundPreciseTime)
{
    CommandList commandList;
    string preciseTime = FormatDouble(foundPreciseTime);
    
    commandList.Content = "# Found precise time: " + preciseTime + "\n";
    commandList.Content += simManager.InputEvents.ToCommandsText(InputFormatFlags(3));
    commandList.Save(_resultFileName + "_" + preciseTime + "_" + _currentReplayIndex + ".txt");
    
    Log("Saved precise time for input file \"" + _resultFileName + "" + _currentReplayIndex + "\": " + preciseTime, Severity::Success);
}

void LoadInputsForReplayWithIndex(int index, SimulationManager@ simManager)
{
    CommandList commandList(_resultFileName + _currentReplayIndex + ".txt");
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
    if (!_isPluginSelectedByUser)
    {
        _resultFileName = UI::InputTextVar("File name", "fic_pte_file_name");
    }
    else
    {
        UI::Text("File name " + _resultFileName);
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
