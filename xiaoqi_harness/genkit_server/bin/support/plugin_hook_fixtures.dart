/// Trusted fixtures shared by native launch verification and the Docker Agent
/// gate, so Python/stdin/output compatibility is tested before a costly build.
const hookGatePreScript = r'''
import json,sys
value=json.load(sys.stdin)
assert value['hook_event_name']=='PreToolUse' and value['tool_name']=='Bash'
command=value['tool_input']['command']
assert 'agent-shell-verified' in command
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
