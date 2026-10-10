import os
import json
import urllib.request
import urllib.error
from flask import Flask, Response, jsonify, request, stream_with_context

app = Flask(__name__)

TIMEOUT = 120


def _provider_request(body):
    model_id = str(body.get('model_id') or body.get('model') or 'deepseek-flash').strip()
    normalized_model_id = model_id.lower()
    if normalized_model_id.startswith('mimo'):
        provider_name = 'MiMo'
        key_name = 'MIMO_API_KEY'
        endpoint = 'https://api.xiaomimimo.com/v1/chat/completions'
    elif normalized_model_id.startswith('deepseek'):
        provider_name = 'DeepSeek'
        key_name = 'DEEPSEEK_API_KEY'
        endpoint = 'https://api.deepseek.com/chat/completions'
    else:
        return None, None, None, (jsonify({'error': {'message': '暂不支持此模型'}}), 400)

    api_key = os.environ.get(key_name, '').strip()
    if not api_key:
        return None, None, None, (
            jsonify({'error': {'message': f'{provider_name} 后端 API 尚未配置（{key_name}）'}}),
            503,
        )

    upstream_body = dict(body)
    upstream_body.pop('model_id', None)
    reasoning_level = str(upstream_body.pop('reasoning_level', '')).lower()
    upstream_body['model'] = model_id
    if reasoning_level:
        if normalized_model_id.startswith('mimo'):
            upstream_body.setdefault(
                'thinking',
                {'type': 'disabled' if reasoning_level == 'low' else 'enabled'},
            )
        else:
            upstream_body.setdefault(
                'reasoning_effort',
                {'low': 'low', 'medium': 'high', 'high': 'max'}.get(
                    reasoning_level, 'high'
                ),
            )
    max_output_tokens = upstream_body.pop('max_output_tokens', None)
    if max_output_tokens is not None:
        token_field = (
            'max_completion_tokens'
            if normalized_model_id.startswith('mimo')
            else 'max_tokens'
        )
        upstream_body.setdefault(token_field, max_output_tokens)

    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json',
    }
    return endpoint, headers, upstream_body, None

@app.route('/v1/chat/completions', methods=['POST'])
def proxy():
    try:
        body = request.get_json(force=True)
    except Exception:
        return jsonify({'error': {'message': '请求格式错误'}}), 400
    if not isinstance(body, dict):
        return jsonify({'error': {'message': '请求格式错误'}}), 400

    endpoint, headers, upstream_body, error_response = _provider_request(body)
    if error_response is not None:
        return error_response

    try:
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(upstream_body).encode('utf-8'),
            headers=headers,
            method='POST'
        )
        resp = urllib.request.urlopen(req, timeout=TIMEOUT)
        content_type = resp.headers.get('Content-Type', 'application/json')
        if upstream_body.get('stream') is True:
            def stream_response():
                try:
                    while True:
                        chunk = resp.read1(64 * 1024)
                        if not chunk:
                            break
                        yield chunk
                finally:
                    resp.close()

            return Response(
                stream_with_context(stream_response()),
                status=resp.status,
                content_type=content_type,
                headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'},
            )
        with resp:
            return Response(resp.read(), status=resp.status, content_type=content_type)
    except urllib.error.HTTPError as e:
        return Response(
            e.read(),
            status=e.code,
            content_type=e.headers.get('Content-Type', 'application/json'),
        )
    except Exception as e:
        return jsonify({'error': {'message': f'AI走神了，稍后再试试~ {str(e)}'}}), 504

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status': 'ok',
        'release_id': os.environ.get('CAPABILITY_API_RELEASE_ID', 'unversioned'),
    })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
