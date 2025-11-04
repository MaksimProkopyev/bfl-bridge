#!/usr/bin/env node
import path from 'node:path';
import crypto from 'node:crypto';
import dotenv from 'dotenv';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const root = process.cwd();
const envPath = path.join(root, '.env.local');
dotenv.config({ path: envPath });

function getEnv(name, { required = false } = {}) {
  const value = process.env[name];
  if (required && (!value || value.trim() === '')) {
    throw new Error(`Missing required env ${name}`);
  }
  return value ? value.trim() : '';
}

const host = getEnv('N8N_HOST', { required: true }).replace(/\/$/, '');
const workflowId = getEnv('WORKFLOW_ID', { required: true });
const apiKey = getEnv('N8N_API_KEY');
const n8nJwt = getEnv('N8N_JWT');
const n8nAdminJwt = getEnv('N8N_ADMIN_JWT');
if (!apiKey && !n8nJwt && !n8nAdminJwt) {
  throw new Error('Missing auth: set N8N_API_KEY or N8N_JWT / N8N_ADMIN_JWT');
}
getEnv('WEBHOOK_BASE_URL', { required: true });
const leadgenAHeader = {
  name: 'Authorization',
  value: '{{$env.LEADGEN_A_AUTH}}',
  disabled: "={{ !$env.LEADGEN_A_AUTH }}",
};
const leadgenBHeader = {
  name: 'Authorization',
  value: '{{$env.LEADGEN_B_AUTH}}',
  disabled: "={{ !$env.LEADGEN_B_AUTH }}",
};

const apiBase = `${host}/rest`;
const execFileAsync = promisify(execFile);

function isTruthy(value) {
  if (!value) return false;
  const normalized = value.trim().toLowerCase();
  return ['1', 'true', 'yes', 'on'].includes(normalized);
}

function parseCurlExtraArgs(raw) {
  if (!raw) {
    return [];
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`Invalid N8N_CURL_EXTRA_ARGS JSON: ${error.message}`);
  }
  if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== 'string')) {
    throw new Error('N8N_CURL_EXTRA_ARGS must be a JSON array of strings');
  }
  return parsed;
}

function buildCurlEnv() {
  const env = { ...process.env };
  const disableProxy = isTruthy(getEnv('N8N_CURL_DISABLE_PROXY'));
  const proxyUrl = getEnv('N8N_CURL_PROXY');
  const noProxy = getEnv('N8N_CURL_NO_PROXY');

  const proxyEnvKeys = [
    'http_proxy',
    'https_proxy',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'all_proxy',
  ];

  if (disableProxy) {
    proxyEnvKeys.forEach((key) => {
      delete env[key];
    });
    delete env.NO_PROXY;
    delete env.no_proxy;
  } else if (proxyUrl) {
    proxyEnvKeys.forEach((key) => {
      env[key] = proxyUrl;
    });
  }

  if (noProxy) {
    env.NO_PROXY = noProxy;
    env.no_proxy = noProxy;
  }

  return env;
}

const curlExtraArgs = parseCurlExtraArgs(getEnv('N8N_CURL_EXTRA_ARGS'));
const curlEnv = buildCurlEnv();

async function curlJsonRequest(pathname, { method = 'GET', body } = {}) {
  const url = `${apiBase}${pathname}`;
  const args = ['-sS', '-o', '-', '-w', '\n%{http_code}', '-X', method, ...curlExtraArgs];
  const headers = {
    'Content-Type': 'application/json',
  };
  if (n8nAdminJwt) {
    headers.Authorization = `Bearer ${n8nAdminJwt}`;
  } else if (n8nJwt) {
    headers.Authorization = `Bearer ${n8nJwt}`;
  } else if (apiKey) {
    headers['X-N8N-API-KEY'] = apiKey;
  }
  Object.entries(headers).forEach(([key, value]) => {
    if (value && value.trim() !== '') {
      args.push('-H', `${key}: ${value}`);
    }
  });
  if (body) {
    args.push('-d', JSON.stringify(body));
  }
  args.push(url);
  let stdout;
  try {
    ({ stdout } = await execFileAsync('curl', args, { env: curlEnv }));
  } catch (error) {
    const message = error?.stderr || error?.message || 'curl execution failed';
    throw new Error(`curl request failed: ${message}`);
  }
  const trimmed = stdout.trimEnd();
  const splitIndex = trimmed.lastIndexOf('\n');
  if (splitIndex === -1) {
    throw new Error('Invalid curl response (missing status code)');
  }
  const bodyText = trimmed.slice(0, splitIndex);
  const statusText = trimmed.slice(splitIndex + 1);
  const statusCode = Number.parseInt(statusText, 10);
  if (Number.isNaN(statusCode)) {
    throw new Error(`Invalid status code from curl: ${statusText}`);
  }
  if (statusCode === 204) {
    return null;
  }
  if (statusCode < 200 || statusCode >= 300) {
    const preview = bodyText.length > 2000 ? `${bodyText.slice(0, 2000)}…` : bodyText;
    throw new Error(`n8n ${method} ${pathname} failed: ${statusCode} ${preview}`);
  }
  if (!bodyText) {
    return null;
  }
  try {
    return JSON.parse(bodyText);
  } catch (error) {
    throw new Error(`Failed to parse JSON response: ${error.message}`);
  }
}

async function apiRequest(pathname, { method = 'GET', body } = {}) {
  return curlJsonRequest(pathname, { method, body });
}

function upsertNode(nodes, node) {
  const idx = nodes.findIndex((n) => n.name === node.name);
  if (idx === -1) {
    nodes.push(node);
    return node;
  }
  nodes[idx] = {
    ...nodes[idx],
    ...node,
    id: nodes[idx].id ?? node.id,
    position: Array.isArray(node.position) ? node.position : nodes[idx].position,
  };
  return nodes[idx];
}

function ensureConnection(connections, sourceName, outputIndex, targetName, targetIndex = 0) {
  if (!connections[sourceName]) {
    connections[sourceName] = { main: [] };
  }
  const source = connections[sourceName];
  while (source.main.length <= outputIndex) {
    source.main.push([]);
  }
  const list = source.main[outputIndex];
  const exists = list.some(
    (entry) => entry.node === targetName && entry.type === 'main' && entry.index === targetIndex,
  );
  if (!exists) {
    list.push({ node: targetName, type: 'main', index: targetIndex });
  }
}

function pruneRemovedConnections(connections, validNodes) {
  const valid = new Set(validNodes.map((n) => n.name));
  Object.keys(connections).forEach((source) => {
    if (!valid.has(source)) {
      delete connections[source];
      return;
    }
    const sourceConn = connections[source];
    if (sourceConn?.main) {
      sourceConn.main = sourceConn.main.map((items = []) =>
        items.filter((entry) => valid.has(entry.node)),
      );
    }
  });
}

function coerceNodeName(nodes, candidates, targetName) {
  const names = Array.isArray(candidates) ? candidates : [candidates];
  const node = nodes.find((n) => names.includes(n.name));
  if (node) {
    node.name = targetName;
  }
  return node;
}

function buildIfNode(name, key, position) {
  return {
    id: crypto.randomUUID(),
    name,
    type: 'n8n-nodes-base.if',
    typeVersion: 2,
    position,
    parameters: {
      conditions: {
        boolean: [
          {
            value1: `{{ Array.isArray($json.actions?.${key}) && $json.actions.${key}.length > 0 }}`,
            value2: true,
          },
        ],
      },
    },
  };
}

function buildHttpNode({ name, pathSuffix, bodyKey, payloadKey, authHeader, position }) {
  const headers = [
    { name: 'Content-Type', value: 'application/json' },
  ];
  if (authHeader) {
    headers.push({ ...authHeader });
  }
  const baseUrlExpr = "($env.WEBHOOK_BASE_URL || '').replace(/\\\/$/, '')";
  const urlExpr = `${baseUrlExpr} + '${pathSuffix}'`;
  const bodyExpr = `{{ { ${payloadKey}: $json('actions.${bodyKey}') } }}`;
  return {
    id: crypto.randomUUID(),
    name,
    type: 'n8n-nodes-base.httpRequest',
    typeVersion: 4,
    position,
    parameters: {
      url: `{{ ${urlExpr} }}`,
      method: 'POST',
      jsonParameters: true,
      bodyParametersJson: bodyExpr,
      headerParameters: headers,
      options: {
        retryOnFail: true,
        maxRetries: 3,
        retry: 3,
        timeout: 15000,
      },
    },
  };
}

(async () => {
  try {
    const workflow = await apiRequest(`/workflows/${encodeURIComponent(workflowId)}`);
    if (!workflow || !workflow.nodes) {
      throw new Error('Invalid workflow payload');
    }

    const nodes = workflow.nodes;
    const connections = workflow.connections || {};
    const extractNode = nodes.find((n) => n.name === 'Extract Actions');
    const returnNode = nodes.find((n) => n.name === 'Return' || n.name === 'Return (Respond to Webhook)');

    if (!extractNode) {
      throw new Error('Extract Actions node not found');
    }
    if (!returnNode) {
      throw new Error('Return node not found');
    }

    const baseX = Array.isArray(extractNode.position) ? extractNode.position[0] : 0;
    const baseY = Array.isArray(extractNode.position) ? extractNode.position[1] : 0;

    const existingHasToA = coerceNodeName(nodes, ['has_to_a', 'Has to A', 'Has to a'], 'has_to_a');
    const existingHasToB = coerceNodeName(nodes, ['has_to_b', 'Has to B', 'Has to b'], 'has_to_b');

    const hasToAPosition = Array.isArray(existingHasToA?.position)
      ? existingHasToA.position
      : [baseX + 300, baseY - 150];
    const hasToBPosition = Array.isArray(existingHasToB?.position)
      ? existingHasToB.position
      : [baseX + 300, baseY + 150];

    const hasToANode = buildIfNode('has_to_a', 'to_a', hasToAPosition);
    const hasToBNode = buildIfNode('has_to_b', 'to_b', hasToBPosition);

    const existingHttpA = coerceNodeName(nodes, ['HTTP A', 'leadgen_a_http', 'HTTP A Request'], 'HTTP A');
    const existingHttpB = coerceNodeName(nodes, ['HTTP B', 'leadgen_b_http', 'HTTP B Request'], 'HTTP B');

    const httpAPosition = Array.isArray(existingHttpA?.position)
      ? existingHttpA.position
      : [baseX + 600, baseY - 150];
    const httpBPosition = Array.isArray(existingHttpB?.position)
      ? existingHttpB.position
      : [baseX + 600, baseY + 150];

    const httpANode = buildHttpNode({
      name: 'HTTP A',
      pathSuffix: '/webhook/bfl/leadgen/query-a',
      bodyKey: 'to_a',
      payloadKey: 'new_urls',
      authHeader: leadgenAHeader,
      position: httpAPosition,
    });

    const httpBNode = buildHttpNode({
      name: 'HTTP B',
      pathSuffix: '/webhook/bfl/leadgen/intake-b',
      bodyKey: 'to_b',
      payloadKey: 'candidates',
      authHeader: leadgenBHeader,
      position: httpBPosition,
    });

    const upsertedHasToA = upsertNode(nodes, hasToANode);
    const upsertedHasToB = upsertNode(nodes, hasToBNode);
    const upsertedHttpA = upsertNode(nodes, httpANode);
    const upsertedHttpB = upsertNode(nodes, httpBNode);

    ensureConnection(connections, extractNode.name, 0, upsertedHasToA.name, 0);
    ensureConnection(connections, extractNode.name, 0, upsertedHasToB.name, 0);
    ensureConnection(connections, extractNode.name, 0, returnNode.name, 0);
    ensureConnection(connections, upsertedHasToA.name, 0, upsertedHttpA.name, 0);
    ensureConnection(connections, upsertedHasToB.name, 0, upsertedHttpB.name, 0);

    pruneRemovedConnections(connections, nodes);

    function ensureReturnJson(node) {
      const bodyExpr =
        "{{ { ok:true, counts:{ to_a: Array.isArray($json.actions?.to_a)?$json.actions.to_a.length:0, to_b: Array.isArray($json.actions?.to_b)?$json.actions.to_b.length:0 } } }}";
      node.parameters = node.parameters || {};
      node.parameters.responseBodyExpression = bodyExpr;
      node.parameters.responseCode = 200;
      if (node.name !== 'Return (Respond to Webhook)') {
        node.name = 'Return (Respond to Webhook)';
      }
    }

    ensureReturnJson(returnNode);

    workflow.nodes = nodes;
    workflow.connections = connections;

    await apiRequest(`/workflows/${encodeURIComponent(workflowId)}`, {
      method: 'PATCH',
      body: workflow,
    });

    console.log('patch: OK');
  } catch (error) {
    console.error(`patch: ${error.message}`);
    process.exitCode = 1;
  }
})();
