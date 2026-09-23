#!/bin/bash
# Double-click in Finder to start the bridge in its own Terminal window (macOS).
# Same as `npm start`; close the window or press Ctrl+C to stop it.
cd "$(dirname "$0")" || exit 1
exec node supervisor.js "$@"
