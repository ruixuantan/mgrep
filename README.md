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

Run mgrep on multiple files with multiple configs:
```sh
./zig-out/bin/mgrep -hn "pattern" filename1.txt filename2.txt
```

## Features
### mgrep flags:
| Flag | Desc. |
| - | - |
| `-c` | Prints count of lines containing pattern (not count of matched patterns) |
| `-h` | Displays filename next to matched line |
| `-l` | Prints list of files containing at least 1 line with a match |
| `-n` | Displays line number next to matched line |
| `-v` | Matches based on negation of pattern |

### regex features
| Pattern | Desc. |
| - | - |
| `[abc]` | A single character of a, b or c |
| `[^abc]` | A single character that is not a, b or c |
| `[a-z]` | A single character in the range a to z |
| `[^a-z]` | A single character not in the range a to z |
| `[a-zA-Z]` | A single character in the range a to z and A to Z |
| `.` | Any single character |
| `a\|b` | Either a or b |
| `\s` | A whitespace character |
| `\S` | A non-whitespace character |
| `\d` | A digit character |
| `\D` | A non-digit character |
| `\w` | A word character |
| `\W` | A non-word character |
| `a*` | Zero or more of a |
| `a+` | One or more of a |
| `a?` | Zero or one of a |
| `a{3}` | Exactly three of a |
| `a{3,}` | Three or more of a |
| `a{,3}` | Zero to three of a |
| `a{3,5}` | Between three to five of a |
| `a*?` | Lazy quantifier |

### Unavailable features
* Directory searching
* Anchors
* Backreferencing
* Possessive matching
