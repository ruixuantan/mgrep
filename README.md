# mgrep
A simple clone of grep (ASCII only), written in Zig (0.13.0).
With a simplistic epsilon-nfa regex engine implemented.

Credits to this tutorial: https://rhaeguard.github.io/posts/regex/

## Usage
Unit tests:
```sh
zig build test
```

Build:
```sh
zig build --release=safe
```

Run mgrep on a file:
```sh
./zig-out/bin/mgrep "pattern" filename.txt
```
