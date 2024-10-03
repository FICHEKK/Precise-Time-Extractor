const string PLUGIN_NAME = "fic's Precise Time Extractor";
const string PLUGIN_ID = "fic_pte"; // fic = author, pte = Precise Time Extractor

const string SETTING_BASE_REPLAY_NAME = PLUGIN_ID + "_base_replay_name";
const string SETTING_MIN_REPLAY_INDEX = PLUGIN_ID + "_min_replay_index";
const string SETTING_MAX_REPLAY_INDEX = PLUGIN_ID + "_max_replay_index";
const string SETTING_OUTPUT_FOLDER = PLUGIN_ID + "_output_folder";

bool _isPluginCurrentlyUsed = false;
SimulationState@ _stateAtRaceStart;
int _currentReplayIndex;
int _bestReplayIndex;

string _baseReplayName;
int _minReplayIndex;
int _maxReplayIndex;
string _outputFolder;

namespace PreciseTime
{
    double lastFound;
    double bestFound;
    
    BFPhase searchPhase = BFPhase::Initial;
    bool isFirstSearchIteration = true;
    uint64 coeffMin = 0;
    uint64 coeffMax = 18446744073709551615; 
    SimulationState@ stateBeforeFinishing;
    
    // Returns true if calculating precise time for currently loaded replay has been complete.
    bool Calculate(SimulationManager@ simManager)
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
        if (PreciseTime::isFirstSearchIteration)
        {
            // We can't modify coefficient in the first iteration as we first need to simulate
            // the 0.5 coefficient to determine in which way to continue the binary search.
            PreciseTime::isFirstSearchIteration = false;
        }
        else
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

        simManager.RewindToState(PreciseTime::stateBeforeFinishing);
        uint64 currentCoeff = PreciseTime::coeffMin + (PreciseTime::coeffMax - PreciseTime::coeffMin) / 2;
        double currentCoeffPercentage = currentCoeff / 18446744073709551615.0;

        if (PreciseTime::coeffMax - PreciseTime::coeffMin > 1)
        {
            simManager.Dyna.CurrentState.LinearSpeed *= currentCoeffPercentage;
            simManager.Dyna.CurrentState.AngularSpeed *= currentCoeffPercentage;
            return BFEvaluationDecision::DoNothing;
        }

        PreciseTime::isFirstSearchIteration = true;
        PreciseTime::coeffMin = 0;
        PreciseTime::coeffMax = 18446744073709551615;
        PreciseTime::lastFound = (simManager.RaceTime / 1000.0) + (currentCoeffPercentage / 100.0);
        if (PreciseTime::lastFound < PreciseTime::bestFound) PreciseTime::bestFound = PreciseTime::lastFound;

        return BFEvaluationDecision::Accept;
    }
}

void OnSimulationBegin(SimulationManager@ simManager)
{
    _isPluginCurrentlyUsed = GetVariableString("controller") == PLUGIN_ID;
    if (!_isPluginCurrentlyUsed) return;
        
    simManager.RemoveStateValidation();
    simManager.InputEvents.RemoveAt(simManager.InputEvents.Length - 1);

    _baseReplayName = GetVariableString(SETTING_BASE_REPLAY_NAME);
    _currentReplayIndex = int(GetVariableDouble(SETTING_MIN_REPLAY_INDEX));
    _bestReplayIndex = _currentReplayIndex;
    _outputFolder = GetVariableString(SETTING_OUTPUT_FOLDER);

    PreciseTime::searchPhase = BFPhase::Initial;
    PreciseTime::isFirstSearchIteration = true;
    PreciseTime::coeffMin = 0;
    PreciseTime::coeffMax = 18446744073709551615;
    PreciseTime::bestFound = Math::UINT64_MAX;
    
    int totalInputFiles = _maxReplayIndex - _minReplayIndex + 1;
    Log("Starting precise time extraction for " + totalInputFiles + " input file" + (totalInputFiles > 1 ? "s" : "") + "...");
    LoadInputsForReplayWithIndex(_currentReplayIndex, simManager);
}

void OnSimulationStep(SimulationManager@ simManager, bool userCancelled)
{
    if (!_isPluginCurrentlyUsed || userCancelled)
    {
        OnSimulationEnd(simManager, 0);
        return;
    }
    
    if (simManager.TickTime == 0) @_stateAtRaceStart = simManager.SaveState();

    bool hasCalculatedPreciseTimeForCurrentReplay = PreciseTime::Calculate(simManager);
    if (!hasCalculatedPreciseTimeForCurrentReplay) return;

    SavePreciseTimeForCurrentReplay(simManager);
    if (PreciseTime::lastFound == PreciseTime::bestFound) _bestReplayIndex = _currentReplayIndex;
    
    if (++_currentReplayIndex > _maxReplayIndex)
    {
        Log("All replays have been processed! Best replay was \"" + _baseReplayName + "" + _bestReplayIndex + "\" with time of " + FormatDouble(PreciseTime::bestFound) + ".");
        OnSimulationEnd(simManager, 0);
        return;
    }
    
    LoadInputsForReplayWithIndex(_currentReplayIndex, simManager);
    simManager.RewindToState(_stateAtRaceStart);
}

void OnCheckpointCountChanged(SimulationManager@ simManager, int count, int target)
{
    if (!_isPluginCurrentlyUsed) return;
    if (simManager.PlayerInfo.RaceFinished) simManager.PreventSimulationFinish();
}

void OnSimulationEnd(SimulationManager@ simManager, uint result)
{
    if (!_isPluginCurrentlyUsed) return;
    
    _isPluginCurrentlyUsed = false;
    simManager.SetSimulationTimeLimit(0.0);
}

void SavePreciseTimeForCurrentReplay(SimulationManager@ simManager)
{
    string preciseTime = FormatDouble(PreciseTime::lastFound);
    
    CommandList commandList;
    commandList.Content = "# Precise time: " + preciseTime + "\n";
    commandList.Content += simManager.InputEvents.ToCommandsText(InputFormatFlags(3));
    
    string folderToSaveTo = "";
    if (_outputFolder != "") folderToSaveTo = _outputFolder + "\\";
    commandList.Save(folderToSaveTo + _baseReplayName + "_" + preciseTime + "_" + _currentReplayIndex + ".txt");
    
    Log("Saved precise time for input file \"" + _baseReplayName + "" + _currentReplayIndex + "\": " + preciseTime, Severity::Success);
}

void LoadInputsForReplayWithIndex(int index, SimulationManager@ simManager)
{
    CommandList commandList(_baseReplayName + _currentReplayIndex + ".txt");
    commandList.Process(CommandListProcessOption::ExecuteImmediately);
    SetCurrentCommandList(commandList);
    simManager.InputEvents.Clear();
    
    for (uint i = 0; i < commandList.InputCommands.Length; i++)
    {
        InputCommand event = commandList.InputCommands[i];
        simManager.InputEvents.Add(event.Timestamp, event.Type, event.State);
    }
}

void Log(string message, Severity severity = Severity::Info)
{
    const string prefix = "[PTE]";
    print(prefix + " " + message, severity);
}

string FormatDouble(double value)
{
    const int precision = 16;
    return Text::FormatFloat(value, "", 0, precision);
}

void Main()
{
    RegisterVariable(SETTING_BASE_REPLAY_NAME, "track");
    RegisterVariable(SETTING_MIN_REPLAY_INDEX, 1);
    RegisterVariable(SETTING_MAX_REPLAY_INDEX, 5);
    RegisterVariable(SETTING_OUTPUT_FOLDER, PLUGIN_NAME);
    
    RegisterValidationHandler(PLUGIN_ID, PLUGIN_NAME, RenderPluginUserInterface);
}

void RenderPluginUserInterface()
{
    RenderSettingsSection();
    RenderHowToUseSection();
    RenderHowItWorksSection();
    RenderMotivationSection();
}

void RenderSettingsSection()
{
    RenderSectionTitle("Settings");

    if (_isPluginCurrentlyUsed)
    {
        UI::Text("Base Replay Name: " + _baseReplayName);
        UI::Text("Min Replay Index: " + _minReplayIndex);
        UI::Text("Max Replay Index: " + _maxReplayIndex);
        return;
    }
    
    _baseReplayName = UI::InputTextVar("Base Replay Name", SETTING_BASE_REPLAY_NAME);
    _minReplayIndex = UI::InputIntVar("Min Replay Index", SETTING_MIN_REPLAY_INDEX);
    _maxReplayIndex = UI::InputIntVar("Max Replay Index", SETTING_MAX_REPLAY_INDEX);
    _outputFolder = UI::InputTextVar("Output Folder", SETTING_OUTPUT_FOLDER);
    
    if (_minReplayIndex < 0)
    {
        _minReplayIndex = 0;
        SetVariable(SETTING_MIN_REPLAY_INDEX, _minReplayIndex);
    }
    
    if (_minReplayIndex > _maxReplayIndex)
    {
        _maxReplayIndex = _minReplayIndex;
        SetVariable(SETTING_MAX_REPLAY_INDEX, _maxReplayIndex);
    }
}

void RenderHowToUseSection()
{
    RenderSectionTitle("How to use?");
    
    UI::TextWrapped("1. Convert all of your replay \".Gbx\" files to TMI input files. You can do that easily via online tool:");
    UI::Dummy(vec2(0, 2));
    UI::TextWrapped("https://io.gbx.tools/extract-inputs-tmi");
    
    RenderSeparator();
    
    UI::TextWrapped("2. Move all of your TMI input files to TMI's \"Scripts\" folder (on Windows, this is usually located at \"C:\\Users\\User\\Documents\\TMInterface\\Scripts\").");
    
    RenderSeparator();
    
    UI::TextWrapped("3. Rename all of your TMI input files so that they have the same base name (specified by \"Base Replay Name\" setting above), but have increasing number suffix.");
    UI::Dummy(vec2(0, 2));
    UI::TextWrapped("For example, if your \"Base Replay Name\" is set to \"track\", your TMI input files should be \"track1.txt\", \"track2.txt\", \"track3.txt\" and so on.");
    
    RenderSeparator();
    
    UI::TextWrapped("4. Set \"Min Replay Index\" and \"Max Replay Index\" to define range of TMI input files for which precise times should be extracted.");
    UI::Dummy(vec2(0, 2));
    UI::TextWrapped("For example, if \"Base Replay Name\" = \"track\", \"Min Replay Index\" = 1 and \"Max Replay Index\" = 3, TMI input files \"track1.txt\", \"track2.txt\" and \"track3.txt\" will be extracted.");
    
    RenderSeparator();
    
    UI::TextWrapped("5. In Trackmania, go to \"Editors\\Edit a Replay\" and select some replay (has to be a replay of the same track as the one you are extracting inputs for), press \"Launch\" and finally \"" + PLUGIN_NAME + "\".");
    
    RenderSeparator();
    
    UI::TextWrapped("6. If everything was setup correctly, new files with extracted precise times for each specified TMI input file will be generated in the folder specified by \"Output Folder\" setting (folder which is relative to TMI's \"Scripts\" folder).");
    UI::Dummy(vec2(0, 2));
    UI::TextWrapped("If \"Output Folder\" setting is empty, new files will be generated directly in TMI's \"Scripts\" folder.");
    UI::Dummy(vec2(0, 8));
}

void RenderHowItWorksSection()
{
    RenderSectionTitle("How it works?");
    UI::TextWrapped("Inner-workings of this plugin are very simple:");
    UI::TextWrapped("1. Loads TMI inputs from a file.");
    UI::TextWrapped("2. Resets car state to the start, resimulates full race and calculates the precise time.");
    UI::TextWrapped("3. Saves results to a new file and performs all of the above steps again for the next file.");
    UI::TextWrapped("4. When all files have been processed, force ends the simulation.");
    UI::Dummy(vec2(0, 8));
}

void RenderMotivationSection()
{
    RenderSectionTitle("Motivation");
    
    UI::TextWrapped("The reason I made this plugin was to solve my own problem.");
    UI::Dummy(vec2(0, 8));
    UI::TextWrapped("I had 344 replay files of a short track that were all equal to 2 digits (all were timed 9.84) and I wanted to see which ones were the closest to 9.83.");
    UI::Dummy(vec2(0, 8));
    UI::TextWrapped("Extracting precise times of 344 replays by manually validating each would take forever, so instead I decided to solve this problem once and for all! :)");
    UI::Dummy(vec2(0, 8));
    UI::TextWrapped("-fic");
}

void RenderSectionTitle(string title)
{
    UI::Dummy(vec2(0, 8));
    UI::TextDimmed(title);
    RenderSeparator(2);
}

void RenderSeparator(float margin = 4)
{
    UI::Dummy(vec2(0, margin));
    UI::Separator();
    UI::Dummy(vec2(0, margin));
}

PluginInfo@ GetPluginInfo()
{
    auto info = PluginInfo();
    info.Name = PLUGIN_NAME;
    info.Author = "fic";
    info.Version = "v1.0.0";
    info.Description = "Plugin that allows you to automatically extract precise times of multiple replay input files.";
    return info;
}
