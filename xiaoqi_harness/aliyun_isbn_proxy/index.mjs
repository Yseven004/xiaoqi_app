const tanShuEndpoint =
  process.env.TANSHU_ENDPOINT ||
  'https://tsisbn.market.alicloudapi.com/isbn/index';
const jisuEndpoint =
  process.env.JISU_ENDPOINT ||
  'https://jisuisbn.market.alicloudapi.com/isbn/query';
const proxyToken = (process.env.XIAOQI_PROXY_TOKEN || '').trim();
const requestTimeoutMs = 4500;

function reply(statusCode, value) {
  return {
    statusCode,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
    body: JSON.stringify(value),
  };
}

function parseEvent(event) {
  if (typeof event === 'string') return JSON.parse(event);
  if (Buffer.isBuffer(event)) return JSON.parse(event.toString('utf8'));
  return event || {};
}

function getHeader(headers, name) {
  const entry = Object.entries(headers || {}).find(
    ([key]) => key.toLowerCase() === name.toLowerCase(),
  );
  return entry ? String(entry[1] || '').trim() : '';
}

function normalizeIsbn(value) {
  return String(value || '').replace(/[\s-]/g, '').toUpperCase();
}

function isBookMetadata(value) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    String(value.title || '').trim().length > 0;
}

async function requestProvider(url, appCode, isbn) {
  const target = new URL(url);
  target.searchParams.set('isbn', isbn);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), requestTimeoutMs);
  try {
    const response = await fetch(target, {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        Authorization: `APPCODE ${appCode}`,
      },
      signal: controller.signal,
    });
    const text = await response.text();
    let body;
    try {
      body = JSON.parse(text);
    } catch (_) {
      return { kind: 'unavailable', reason: 'invalid_json', statusCode: response.status };
    }
    return { kind: 'response', statusCode: response.status, ok: response.ok, body };
  } catch (error) {
    return {
      kind: 'unavailable',
      reason: error?.name === 'AbortError' ? 'timeout' : 'network',
    };
  } finally {
    clearTimeout(timer);
  }
}

async function lookupTanshu(isbn) {
  const appCode = (process.env.TANSHU_APPCODE || '').trim();
  if (!appCode || !tanShuEndpoint) {
    return { kind: 'unavailable', reason: 'not_configured' };
  }
  const response = await requestProvider(tanShuEndpoint, appCode, isbn);
  if (response.kind !== 'response') return response;

  const code = String(response.body?.code ?? '').toLowerCase();
  if (['207802', '213402'].includes(code)) {
    return { kind: 'not_found', provider: 'tanshu' };
  }
  if (!response.ok || (code && !['1', '0', '200', 'success'].includes(code))) {
    return {
      kind: 'unavailable',
      reason: 'upstream_error',
      statusCode: response.statusCode,
      code,
    };
  }

  const data = response.body?.data ?? response.body?.result ?? response.body;
  if (!isBookMetadata(data)) return { kind: 'not_found', provider: 'tanshu' };
  return { kind: 'success', body: response.body, statusCode: response.statusCode };
}

async function lookupJisu(isbn) {
  const appCode = (process.env.JISU_APPCODE || '').trim();
  if (!appCode || !jisuEndpoint) {
    return { kind: 'unavailable', reason: 'not_configured' };
  }
  const response = await requestProvider(jisuEndpoint, appCode, isbn);
  if (response.kind !== 'response') return response;

  const status = String(response.body?.status ?? '');
  if (status === '205') return { kind: 'not_found', provider: 'jisu' };
  if (!response.ok || status !== '0') {
    return {
      kind: 'unavailable',
      reason: 'upstream_error',
      statusCode: response.statusCode,
      code: status,
    };
  }

  const result = response.body?.result;
  let data = result;
  if (Array.isArray(result?.list)) {
    data = result.list.find(
      (item) => normalizeIsbn(item?.isbn) === isbn,
    ) || null;
  }
  if (!isBookMetadata(data)) return { kind: 'not_found', provider: 'jisu' };

  return {
    kind: 'success',
    provider: 'jisu',
    body: {
      code: '1',
      data: {
        ...data,
        isbn: data.isbn || isbn,
        img: data.img || data.pic || '',
      },
    },
  };
}

export const handler = async (event) => {
  let request;
  try {
    request = parseEvent(event);
  } catch (_) {
    return reply(400, { code: 'invalid_event', message: '请求格式错误' });
  }

  if (!proxyToken || getHeader(request.headers, 'x-xiaoqi-proxy-token') !== proxyToken) {
    return reply(401, { code: 'unauthorized', message: '未授权的请求' });
  }

  const query = request.queryParameters || {};
  const isbn = normalizeIsbn(query.isbn);
  if (!/^\d{13}$/.test(isbn)) {
    return reply(400, { code: 'invalid_isbn', message: '请输入有效的 ISBN-13' });
  }

  const configuredPrimary = String(process.env.ISBN_PRIMARY_PROVIDER || 'jisu')
    .trim()
    .toLowerCase();
  const providers = configuredPrimary === 'tanshu'
    ? [['tanshu', lookupTanshu], ['jisu', lookupJisu]]
    : [['jisu', lookupJisu], ['tanshu', lookupTanshu]];
  const outcomes = [];

  for (const [provider, lookup] of providers) {
    let outcome;
    try {
      outcome = await lookup(isbn);
    } catch (_) {
      outcome = { kind: 'unavailable', reason: 'internal' };
    }
    if (outcome.kind === 'success') return reply(200, outcome.body);
    outcomes.push(outcome);
    if (outcome.kind === 'unavailable') {
      console.warn('ISBN provider unavailable', {
        provider,
        reason: outcome.reason,
        statusCode: outcome.statusCode,
        code: outcome.code,
      });
    }
  }

  if (outcomes.every((outcome) => outcome.kind === 'not_found')) {
    return reply(555, {
      code: '207802',
      message: '没有找到相关书籍',
    });
  }
  return reply(502, {
    code: 'upstream_unavailable',
    message: '书目服务暂时不可用',
  });
};
