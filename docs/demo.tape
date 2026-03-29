# demo.tape — ScreenMuse hero GIF
#
# Generates docs/demo.gif showing the full agent recording workflow.
#
# Prerequisites:
#   1. Install VHS: https://github.com/charmbracelet/vhs
#   2. ScreenMuse server running on localhost:7823
#
# Usage:
#   vhs docs/demo.tape
#
# The output GIF lands at docs/demo.gif.

Output docs/demo.gif

# Terminal settings
Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 600
Set Padding 20
Set TypingSpeed 50ms
Set Framerate 30
Set WindowBar Colorful
Set Margin 20
Set BorderRadius 10

# Hidden setup — start with a clean prompt
Hide
Type "clear"
Enter
Sleep 500ms
Show

Sleep 1s

# Step 1: Start a recording session
Type@40ms `curl -X POST localhost:7823/start -d '{"name":"demo"}'`
Sleep 300ms
Enter
Sleep 2s

# Step 2: Mark a chapter
Type@40ms `curl -X POST localhost:7823/chapter -d '{"name":"Step 1"}'`
Sleep 300ms
Enter
Sleep 1.5s

# Step 3: Stop the recording
Type@40ms "curl -X POST localhost:7823/stop"
Sleep 300ms
Enter
Sleep 2s

# Step 4: Export as GIF
Type@40ms `curl -X POST localhost:7823/export -d '{"format":"gif"}'`
Sleep 300ms
Enter
Sleep 2s

# Hold the final frame so viewers can read the output
Sleep 3s
