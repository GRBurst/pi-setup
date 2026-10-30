# `$HOME` of the spelling nono expands (profile grants, environment values), as the absolute path
# the units, activation lines and consumers outside the sandbox read:
# `import ./expand-home.nix {inherit lib;} config.home.homeDirectory "$HOME/.pi-web"`.
{lib}: home: lib.replaceStrings ["$HOME"] [home]
