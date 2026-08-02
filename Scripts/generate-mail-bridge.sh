#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIR:h}"
MAIL_APP="/System/Applications/Mail.app"
BRIDGE_DEFINITION="${REPOSITORY_ROOT}/Documentation/Mail.sdef"
BRIDGE_HEADER="${REPOSITORY_ROOT}/Sources/MailScriptingBridge/include/Mail.h"
BRIDGE_IMPLEMENTATION="${REPOSITORY_ROOT}/Sources/MailScriptingBridge/Mail.m"

if [[ ! -d "${MAIL_APP}" ]]; then
  print -u2 "Mail.app was not found at ${MAIL_APP}."
  exit 1
fi

mkdir -p "${BRIDGE_HEADER:h}"
sdef "${MAIL_APP}" > "${BRIDGE_DEFINITION}"
sdp -fh --basename Mail -o - "${BRIDGE_DEFINITION}" > "${BRIDGE_HEADER}"
sdp -fm --basename Mail -o - "${BRIDGE_DEFINITION}" > "${BRIDGE_IMPLEMENTATION}"

print "Generated Mail.sdef, Mail.h, and Mail.m from ${MAIL_APP}."
