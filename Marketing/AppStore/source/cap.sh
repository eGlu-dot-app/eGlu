#!/bin/zsh
# Puts a simulator's app in a shot and captures it once its page is drawn:
#     cap.sh <device> <shot> <out.png> [ready mode | seconds]
# The shot is state.py's (hero, split, client, start, palette, notes). The
# fourth argument is ready.py's mode for an iPad 13-inch capture, which
# waits until the page shows; or a number of seconds to wait, for other
# screens. shot.sh is the older form of this, with its own yellow check.
set -e
D=$1; SHOT=$2; OUT=$3; READY=${4:-10}
here=${0:A:h}
bundle=${EGLU_CAPTURE_BUNDLE:-net.taehee.safience.MarketingQA}
xcrun simctl terminate $D $bundle 2>/dev/null || true
sleep 1
C=$(xcrun simctl get_app_container $D $bundle data)
python3 $here/state.py "$C" $SHOT >/dev/null
# The window opens on the workspace's first space, not the one it was last in.
rm -rf "$C/Library/Saved Application State/$bundle.savedState"
SIMCTL_CHILD_EGLU_ISOLATED_QA=1 SIMCTL_CHILD_EGLU_DATA_ROOT="$C/Library/Application Support/Safience" \
  xcrun simctl launch $D $bundle >/dev/null
if [[ $READY == <-> ]]; then
  sleep $READY
  [[ $OUT == /dev/null ]] || xcrun simctl io $D screenshot $OUT >/dev/null 2>&1
else
  sleep 6
  for i in {1..20}; do
    xcrun simctl io $D screenshot $OUT >/dev/null 2>&1 && python3 $here/ready.py $OUT $READY && break
    sleep 3
  done
fi
echo "captured $SHOT -> $OUT"
