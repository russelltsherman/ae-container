# Claude Code authenticates inside containers with a long-lived OAuth token
# (CLAUDE_CODE_OAUTH_TOKEN)
#
# The token file is bind-mounted read-only into the container (see
# devcontainer.json). 

# this /etc/profile.d snippet reads and exports CLAUDE_CODE_OAUTH_TOKEN, 
# which login shells and the devcontainer userEnvProbe pick up — so 
# `devc shell`, `devc exec claude -p`, and the VS Code terminal all see it. 
#
# Generate the token once on the host (valid ~1 year) and save it alongside the
# other bot-identity credentials under ~/.bot:
#   claude setup-token            # prints a token; it is NOT saved anywhere
#   mkdir -p ~/.bot/claude
#   printf '%s' '<paste-token>' > ~/.bot/claude/oauth-token
#   chmod 600 ~/.bot/claude/oauth-token

# Export the read-only bind-mounted long lived Claude Code OAuth token, if present
# https://code.claude.com/docs/en/authentication#generate-a-long-lived-token

if [ -r /home/vscode/.bot/claude/oauth-token ]; then
  CLAUDE_CODE_OAUTH_TOKEN="$(cat /home/vscode/.bot/claude/oauth-token)"
  export CLAUDE_CODE_OAUTH_TOKEN
fi