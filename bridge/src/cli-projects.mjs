// Local operator commands use the same locked records and validators as HTTP.
// No app token, project body or attachment path is carried in argv.
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { resolveStateDir } from './config.mjs';
import { badRequest, conflict, notFound } from './errors.mjs';
import { createDecisionStore } from './decisions/store.mjs';
import { isWaiting } from './decisions/service.mjs';
import { createProjectRoutes, createProjectStore } from './routes/projects.mjs';
import { REQUIREMENT_ID, projectRequirements } from './routes/project-requirements.mjs';
import { sessionOptionsReader } from './sessions/options.mjs';
import { composePrompt } from './sessions/service.mjs';
import { createSessionStore, SESSION_ID_PATTERN } from './sessions/store.mjs';
import { assignSessionProject, projectSessionViews, resolveProject } from './sessions/projects.mjs';

export const PROJECTS_USAGE = `laa-bridge projects assign <project name|id> <Work agent UUID|Bridge session ID>
  laa-bridge projects list|get [project] [--json]
  laa-bridge projects rpc                 read an internal project-tool request from stdin`;

const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;

async function readInput() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > 131072) throw badRequest('input_oversize', 'input exceeds 128 KiB');
    chunks.push(chunk);
  }
  try {
    const input = JSON.parse(Buffer.concat(chunks));
    if (input && typeof input === 'object' && !Array.isArray(input)) return input;
  } catch { /* Error contains no input. */ }
  throw badRequest('payload_invalid', 'expected a JSON object');
}

export async function projectsCommand(positional, flags, { stateDir = resolveStateDir(), input = readInput } = {}) {
  const [command, target, sessionId] = positional;
  try {
    if (flags.help) { console.log(PROJECTS_USAGE); return 0; }
    const request = command === 'rpc' ? await input()
      : command === 'assign' ? { op: 'assign', project: target, sessionId }
      : { op: command, project: target, cursor: flags.cursor ?? null };
    const projects = createProjectStore({ file: join(stateDir, 'projects.json') });
    const sessionStore = createSessionStore({ file: join(stateDir, 'sessions.json') });
    const decisions = createDecisionStore({ dir: stateDir });
    const routes = createProjectRoutes({ projects, choices: sessionOptionsReader(),
      projectSessions: (id) => projectSessionViews(sessionStore, id,
        decisions.all().filter((row) => row.status === 'open' || isWaiting(row) || (row.status === 'answered' && row.delivery?.state === 'failed'))),
      sessionMembership: () => new Map(sessionStore.all().map((row) => [row.id, row.projectId])),
    });
    const resolve = () => resolveProject(projects, request.project);
    const handle = (method, path, body) => {
      const route = routes.find((row) => row.method === method && (row.path === path || row.pattern?.test(path)));
      if (!route) throw badRequest('project_operation_invalid', 'unsupported project operation');
      const { status, data } = route.handler({ params: route.pattern?.exec(path).slice(1) ?? [], reuseName: true, internalFullSessions: command === 'rpc',
        rawBody: body === undefined ? undefined : Buffer.from(JSON.stringify(body)),
        req: { url: `${path}${request.op === 'list' ? `?limit=25${request.cursor ? `&cursor=${encodeURIComponent(request.cursor)}` : ''}` : ''}`,
          headers: { 'if-match': request.etag } }, device: { id: 'local-operator' } });
      return { status, data };
    };
    const pathFor = () => `/v1/projects/${resolve().id}`;
    const requirementPath = () => {
      if (typeof request.requirementId !== 'string' || !REQUIREMENT_ID.test(request.requirementId)) {
        throw badRequest('requirement_invalid', 'specify a requirement ID');
      }
      return `${pathFor()}/requirements/${request.requirementId}`;
    };
    let result;
    switch (request.op) {
      case 'list': result = handle('GET', '/v1/projects'); break;
      case 'get': result = handle('GET', pathFor()); break;
      case 'create': result = handle('POST', '/v1/projects', request.body); break;
      case 'update': result = handle('PATCH', pathFor(), request.body); break;
      case 'requirement_add': result = handle('POST', `${pathFor()}/requirements`, request.body); break;
      case 'requirement_update': result = handle('PATCH', requirementPath(), request.body); break;
      case 'requirement_order': result = handle('PUT', `${pathFor()}/requirements/order`, request.body); break;
      case 'requirement_withdraw': result = handle('DELETE', requirementPath()); break;
      case 'prepare': {
        const project = resolve();
        if (project.archivedAt) throw conflict('project_archived', 'choose an active project');
        if (request.requirementId != null && !projectRequirements(project).some((row) => row.id === request.requirementId)) {
          throw notFound('requirement not found');
        }
        if (typeof request.prompt !== 'string' || !request.prompt.trim() || Buffer.byteLength(request.prompt) > 8192) {
          throw badRequest('task_prompt_required', 'expected task prompt up to 8192 bytes');
        }
        const instructions = projects.instructionsFor(project);
        const files = projects.filesFor(project);
        const prompt = instructions || files.length ? composePrompt(project.id, instructions, files, request.prompt) : request.prompt;
        result = { data: { projectId: project.id, prompt } };
        break;
      }
      case 'assign': {
        const project = resolve();
        const external = typeof request.sessionId === 'string' && UUID.test(request.sessionId);
        if (!external && (typeof request.sessionId !== 'string' || !SESSION_ID_PATTERN.test(request.sessionId))) {
          throw badRequest('session_id_invalid', 'use a Work agent UUID or a Bridge session ID');
        }
        let row;
        for (let attempt = 0; attempt <= (external ? 12 : 0); attempt += 1) {
          row = external ? sessionStore.all().find((item) => item.delegate?.sessionId === request.sessionId) : sessionStore.get(request.sessionId);
          if (row) break;
          if (attempt < 12 && external) await sleep(500);
        }
        if (!row) throw notFound('session not yet visible in Bridge; check it and retry assignment');
        const moved = assignSessionProject({ projects, sessionStore, projectId: project.id, sessionId: row.id,
          requirementId: request.requirementId ?? null });
        result = { data: { sessionId: moved.id, projectId: moved.projectId, name: moved.name } };
        break;
      }
      default: throw badRequest('project_operation_invalid', PROJECTS_USAGE);
    }
    console.log(JSON.stringify({ ok: true, ...result }));
    return 0;
  } catch (error) {
    const safeCode = error.status === 404 ? 'project_or_session_not_found' : error.status ? error.code : 'projects_unavailable';
    console.log(JSON.stringify({ ok: false, error: safeCode }));
    return error.status === 404 ? 3 : error.status === 409 || error.status === 412 ? 4 : 1;
  }
}
