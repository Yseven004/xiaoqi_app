/// Trusted fixtures shared by native launch verification and the Docker Agent
/// gate, so Python/stdin/output compatibility is tested before a costly build.
const hookGateShellCode = r'''set -eu
python3 - <<'PY'
import json, pathlib
manifest = json.loads(pathlib.Path('/workspace/input_manifest.json').read_text())
item = next(item for item in manifest['inputs'] if item['name'] == 'agent.txt')
assert pathlib.Path(item['path']).read_text() == 'agent-mcp-payload'
PY
printf '%s' "$1" > /workspace/output/agent-helper.txt
''';
const hookGateShellArguments = ['agent-shell-verified'];

const hookGatePreScript = r'''
import json,sys
value=json.load(sys.stdin)
assert value['hook_event_name']=='PreToolUse' and value['tool_name']=='Bash'
command=value['tool_input']['command']
assert '/workspace/input_manifest.json' in command and 'agent-mcp-payload' in command
assert value['tool_input']['arguments']==['agent-shell-verified']
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','updatedInput':{
 'command':command+'\nprintf "hook-shell-verified" > /workspace/output/hook-verified.txt\n'
}}}))
''';

const hookGatePostScript = r'''
import json,sys
value=json.load(sys.stdin)
assert value['hook_event_name']=='PostToolUse' and value['tool_name']=='Bash'
assert 'hook-verified.txt' in str(value['tool_response'])
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':'hook-post-verified'}}))
''';
