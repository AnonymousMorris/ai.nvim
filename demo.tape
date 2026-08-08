Require nvim
Require pi

Output "assets/demo.gif"

Set Shell "bash"
Set Width 1200
Set Height 720
Set Padding 0
Set FontSize 18
Set FontFamily "Hack Nerd Font Mono"
Set Theme "Catppuccin Mocha"
Set Framerate 30
Set TypingSpeed 60ms
Set CursorBlink false

Hide
Type "nvim lua/ai/init.lua"
Enter
Sleep 3s
Show

Sleep 1s
Type ":AI"
Sleep 500ms
Enter
Sleep 2s

Type "What is this project doing?"
Enter
Sleep 25s
