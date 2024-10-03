# ❓ What is it?
`Precise Time Extractor` is a [Trackmania Interface (TMI)](https://donadigo.com/tminterface/) plugin that allows users to easily extract precise times (times that are not limited to 2 decimals) of multiple TMI input files at once.

![Demonstration](Demonstration.gif)

# 🛠️ Installation
1. Download `PreciseTimeExtractor.as`.
2. Place it inside your TMI `Plugins` folder (on Windows, it is usually located at `C:\Users\User\Documents\TMInterface\Plugins`).
3. To activate it inside TMI, go to `Settings/Bruteforce` and select `fic's Precise Time Extractor` from the dropdown.

# 🧑‍💻 How to use?
1. Convert all of your replay `.Gbx` files to TMI input files. You can do that easily via online tool: [TMI inputs extractor](https://io.gbx.tools/extract-inputs-tmi)<br/><br/>
2. Move all of your TMI input files to TMI's `Scripts` folder (on Windows, this is usually located at `C:\Users\User\Documents\TMInterface\Scripts`).<br/><br/>
3. Rename all of your TMI input files so that they have the same base name (specified by `Base Replay Name` setting), but have increasing number suffix.<br/>
For example, if your `Base Replay Name` is set to `track`, your TMI input files should be `track1.txt`, `track2.txt`, `track3.txt` and so on.<br/><br/>
4. Set `Min Replay Index` and `Max Replay Index` to define range of TMI input files for which precise times should be extracted.<br/>
For example, if `Base Replay Name` = `track`, `Min Replay Index` = `1` and `Max Replay Index` = `3`, TMI input files `track1.txt`, `track2.txt` and `track3.txt` will be extracted.<br/><br/>
5. In Trackmania, go to `Editors\Edit a Replay` and select some replay (has to be a replay of the same track as the one you are extracting inputs for), press `Launch` and finally `fic's Precise Time Extractor`.<br/><br/>
6. If everything was setup correctly, new files with extracted precise times for each specified TMI input file will be generated in the folder specified by `Output Folder` setting (folder which is relative to TMI's `Scripts` folder).
If `Output Folder` setting is empty, new files will be generated directly in TMI's `Scripts` folder.

# ⚙️ How it works?
Inner-workings of this plugin are very simple:
1. Loads TMI inputs from a file.
2. Resets car state to the start, resimulates full race and calculates the precise time.
3. Saves results to a new file and performs all of the above steps again for the next file.
4. When all files have been processed, force ends the simulation.

# 💡 Motivation
The reason I made this plugin was to solve my own problem.

I had 344 replay files of a short track that were all equal to 2 digits (all were timed 9.84) and I wanted to see which ones were the closest to 9.83.

Extracting precise times of 344 replays by manually validating each would take forever, so instead I decided to solve this problem once and for all! :)

If you reached this point, thank you for reading!

-fic
