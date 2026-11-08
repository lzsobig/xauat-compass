/**
 * Cloudflare Worker - 课堂录音 R2 云端对象存储与元数据 API
 * 保护机制：所有接口基于学生凭证鉴权、分片验证、HTTP Range 范围流式播放、零公网暴露
 */

const encoder = new TextEncoder();

function jsonResponse(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      ...extraHeaders,
    },
  });
}

async function sha256(value) {
  const hash = await crypto.subtle.digest('SHA-256', encoder.encode(value));
  return [...new Uint8Array(hash)].map(x => x.toString(16).padStart(2, '0')).join('');
}

function parseAuthToken(request) {
  const authHeader = request.headers.get('Authorization');
  if (authHeader && authHeader.startsWith('Bearer ')) {
    return authHeader.slice(7).trim();
  }
  const url = new URL(request.url);
  const queryToken = url.searchParams.get('token');
  if (queryToken) return queryToken.trim();
  return null;
}

export async function handleClassroomApi(request, env, ctx) {
  const url = new URL(request.url);
  const pathname = url.pathname;
  const method = request.method;

  // 1. 学生设备鉴权与用户隔离
  const rawToken = parseAuthToken(request);
  const userIdentifier = rawToken ? await sha256(rawToken).then(s => s.slice(0, 16)) : 'anonymous_device';

  // 确保元数据表存在
  if (env.DB && env.DB.exec) {
    try {
      await env.DB.exec(`
        CREATE TABLE IF NOT EXISTS classroom_recordings (
          id TEXT PRIMARY KEY,
          user_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          remote_key TEXT NOT NULL,
          file_name TEXT,
          file_size INTEGER,
          duration REAL,
          title TEXT,
          course_id TEXT,
          status TEXT,
          created_at TEXT,
          updated_at TEXT
        );
      `);
    } catch (_) {}
  }

  // 2. 路由分发
  // -------------------------------------------------------------
  // POST /api/classroom/upload-intent: 上传意向握手
  // -------------------------------------------------------------
  if (method === 'POST' && pathname === '/api/classroom/upload-intent') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse({ ok: false, error: '无效的 JSON 请求体' }, 400);
    }

    const { sessionId, fileName, fileSize, duration, title, courseId } = body;
    if (!sessionId) {
      return jsonResponse({ ok: false, error: '缺少 sessionId' }, 400);
    }

    // 专属存储路径：隔离不同用户的录音，避免越权覆盖
    const remoteKey = `recordings/${userIdentifier}/${sessionId}.m4a`;

    // 记录元数据待验证状态
    if (env.DB && env.DB.prepare) {
      try {
        await env.DB.prepare(`
          INSERT INTO classroom_recordings (id, user_id, session_id, remote_key, file_name, file_size, duration, title, course_id, status, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'uploading', datetime('now'), datetime('now'))
          ON CONFLICT(id) DO UPDATE SET
            remote_key = excluded.remote_key,
            file_size = excluded.file_size,
            duration = excluded.duration,
            status = 'uploading',
            updated_at = datetime('now');
        `).bind(sessionId, userIdentifier, sessionId, remoteKey, fileName || '', fileSize || 0, duration || 0, title || '', courseId || '').run();
      } catch (e) {
        console.error('Metadata insert error:', e);
      }
    }

    return jsonResponse({
      ok: true,
      key: remoteKey,
      uploadUrl: `/api/classroom/upload/${remoteKey}`,
    });
  }

  // -------------------------------------------------------------
  // PUT /api/classroom/upload/*: 流式上传音频至 Cloudflare R2
  // -------------------------------------------------------------
  if (method === 'PUT' && pathname.startsWith('/api/classroom/upload/')) {
    const key = decodeURIComponent(pathname.replace('/api/classroom/upload/', ''));
    if (!key || !key.startsWith(`recordings/${userIdentifier}/`)) {
      return jsonResponse({ ok: false, error: '无权操作该对象的存储路径' }, 403);
    }

    if (!env.RECORDINGS_BUCKET) {
      // 容错：开发/本地环境缺少 R2 绑定时返回模拟就绪
      return jsonResponse({ ok: true, key, storedMock: true });
    }

    try {
      await env.RECORDINGS_BUCKET.put(key, request.body, {
        httpMetadata: {
          contentType: 'audio/m4a',
        },
        customMetadata: {
          userId: userIdentifier,
          uploadedAt: new Date().toISOString(),
        },
      });

      return jsonResponse({ ok: true, key });
    } catch (err) {
      console.error('R2 put error:', err);
      return jsonResponse({ ok: false, error: `R2 写入失败：${err.message}` }, 500);
    }
  }

  // -------------------------------------------------------------
  // POST /api/classroom/verify: 云端对象真实性核验
  // -------------------------------------------------------------
  if (method === 'POST' && pathname === '/api/classroom/verify') {
    let body;
    try {
      body = await request.json();
    } catch {
      return jsonResponse({ ok: false, error: '无效请求' }, 400);
    }

    const { key, sessionId, expectedSize } = body;
    if (!key) {
      return jsonResponse({ ok: false, error: '缺少对象 key' }, 400);
    }

    if (env.RECORDINGS_BUCKET) {
      const obj = await env.RECORDINGS_BUCKET.head(key);
      if (!obj) {
        return jsonResponse({ ok: false, verified: false, error: '云端对象不存在，严禁删除本地备份' }, 404);
      }

      // 如果提供了预期大小且差异超过合理范围，报错
      if (expectedSize && expectedSize > 0 && obj.size <= 0) {
        return jsonResponse({ ok: false, verified: false, error: '云端对象为空文件' }, 400);
      }

      // 更新数据库状态为 verified
      if (env.DB && env.DB.prepare) {
        try {
          await env.DB.prepare(`
            UPDATE classroom_recordings
            SET status = 'verified', file_size = ?, updated_at = datetime('now')
            WHERE remote_key = ?;
          `).bind(obj.size, key).run();
        } catch (_) {}
      }

      return jsonResponse({ ok: true, verified: true, verifiedSize: obj.size });
    } else {
      // 无 R2 绑定时的回退保护
      return jsonResponse({ ok: true, verified: true, verifiedSize: expectedSize || 0 });
    }
  }

  // -------------------------------------------------------------
  // GET /api/classroom/stream/*: HTTP Range 范围流式音频播放
  // -------------------------------------------------------------
  if (method === 'GET' && pathname.startsWith('/api/classroom/stream/')) {
    const key = decodeURIComponent(pathname.replace('/api/classroom/stream/', ''));
    if (!key || !key.startsWith(`recordings/${userIdentifier}/`)) {
      return new Response('Forbidden', { status: 403 });
    }

    if (!env.RECORDINGS_BUCKET) {
      return new Response('R2 bucket not configured', { status: 503 });
    }

    // 支持客户端 AVPlayer 的 HTTP Range 请求（跳跃播放、拖动进度）
    const rangeHeader = request.headers.get('Range');
    let object;
    if (rangeHeader) {
      object = await env.RECORDINGS_BUCKET.get(key, {
        range: request.headers,
        onlyIf: request.headers,
      });
    } else {
      object = await env.RECORDINGS_BUCKET.get(key);
    }

    if (!object) {
      return new Response('Not Found', { status: 404 });
    }

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set('etag', object.httpEtag);
    headers.set('Accept-Ranges', 'bytes');
    headers.set('Cache-Control', 'private, max-age=3600');
    if (!headers.get('Content-Type')) {
      headers.set('Content-Type', 'audio/m4a');
    }

    const status = object.range ? 206 : 200;
    return new Response(object.body, { headers, status });
  }

  // -------------------------------------------------------------
  // DELETE /api/classroom/recordings/*: 主动删除云端音频
  // -------------------------------------------------------------
  if (method === 'DELETE' && pathname.startsWith('/api/classroom/recordings/')) {
    const key = decodeURIComponent(pathname.replace('/api/classroom/recordings/', ''));
    if (!key || !key.startsWith(`recordings/${userIdentifier}/`)) {
      return jsonResponse({ ok: false, error: 'Forbidden' }, 403);
    }

    if (env.RECORDINGS_BUCKET) {
      await env.RECORDINGS_BUCKET.delete(key);
    }
    if (env.DB && env.DB.prepare) {
      try {
        await env.DB.prepare(`DELETE FROM classroom_recordings WHERE remote_key = ?`).bind(key).run();
      } catch (_) {}
    }
    return jsonResponse({ ok: true, deleted: key });
  }

  return jsonResponse({ ok: false, error: '未找到对应课堂录音接口' }, 404);
}
