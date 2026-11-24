Output demo.gif

Set Shell bash
Set FontSize 18
Set Width 800
Set Height 460
Set Padding 20
Set TypingSpeed 90ms

# A throwaway HOME so the shell envsh opens gets a plain prompt that shows ENVSH.
Hide
Type `export HOME=$(mktemp -d) SHELL=$(command -v bash) BASH_SILENCE_DEPRECATION_WARNING=1 PATH=$PWD/zig-out/bin:$PATH`
Enter
Type `echo 'PS1="${ENVSH:+[$ENVSH] }\$ "' > $HOME/.bashrc; bind 'set show-mode-in-prompt off'; PS1='$ '; clear`
Enter
Show

Type "cat .env .env.test"
Enter
Sleep 2s

Type "echo $FOO"
Enter
Sleep 2s

Type "envsh"
Enter
Sleep 2s

Type "echo $FOO"
Enter
Sleep 2s

Type "exit"
Enter
Sleep 2s

Type "envsh .env.test"
Enter
Sleep 2s

Type "echo $FOO"
Enter
Sleep 3s
