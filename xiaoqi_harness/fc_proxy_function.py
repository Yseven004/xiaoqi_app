import os
import json
import urllib.request
import urllib.error
from flask import Flask, request, jsonify

app = Flask(__name__)

DEEPSEEK_API_KEY = os.environ.get('DEEPSEEK_API_KEY', '')
DEEPSEEK_BASE_URL = 'https://api.deepseek.com/v1/chat/completions'
TIMEOUT = 18

@app.route('/v1/chat/completions', methods=['POST'])
def proxy():
    if not DEEPSEEK_API_KEY:
        return jsonify({'error': {'message': 'API Key未配置'}}), 500

    try:
        body = request.get_json(force=True)
    except Exception:
        return jsonify({'error': {'message': '请求格式错误'}}), 400

    headers = {
        'Authorization': f'Bearer {DEEPSEEK_API_KEY}',
        'Content-Type': 'application/json'
    }

    try:
        req = urllib.request.Request(
            DEEPSEEK_BASE_URL,
            data=json.dumps(body).encode('utf-8'),
            headers=headers,
            method='POST'
        )
        resp = urllib.request.urlopen(req, timeout=TIMEOUT)
        return (resp.read(), 200, {'Content-Type': 'application/json'})
    except urllib.error.HTTPError as e:
        return (e.read(), e.code, {'Content-Type': 'application/json'})
    except Exception as e:
        return jsonify({'error': {'message': f'AI走神了，稍后再试试~ {str(e)}'}}), 504

@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
