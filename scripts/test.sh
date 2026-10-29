#!/bin/zsh
# Runs the protocol tests. With only the Command Line Tools installed, SwiftPM needs to be
# pointed at the Testing framework; with Xcode installed this is a plain `swift test`.
set -euo pipefail
cd "${0:A:h}/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ -d $F/Testing.framework ]] && ! xcode-select -p | grep -q Xcode.app; then
  swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
else
  swift test
fi
