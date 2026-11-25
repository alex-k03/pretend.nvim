# Run from the repository root: vhs demo/demo.tape
Output demo/demo.gif

Require git
Require nvim

Set Shell "zsh"
Set FontFamily "JetBrainsMonoNL Nerd Font"
Set FontSize 16
Set Width 1200
Set Height 720
Set Padding 16
Set WindowBar Colorful
Set BorderRadius 10
Set TypingSpeed 50ms

Hide
Type "REPO=$PWD && sh demo/setup.sh"
Enter
Sleep 500ms
Type 'cd /tmp/pretend-nvim-demo && nvim -c "set rtp^=$REPO" src/server.py'
Enter
Sleep 2s
Show

Sleep 1.2s
Type ":Pretend"
Enter
Sleep 1.8s

# Select newest commit (HEAD) and oldest commit (main) for the full branch range
Tab
Sleep 600ms
Down
Sleep 300ms
Down
Sleep 500ms
Tab
Sleep 1s
Enter
Sleep 2.5s

# Toggle the in-buffer inline diff overlay to see previous/deleted lines
Type ":Pretend overlay"
Enter
Sleep 3.5s

# Stop pretending and return to the branch
Type ":Pretend done"
Enter
Sleep 2.5s
