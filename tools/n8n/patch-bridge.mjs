#!/usr/bin/env node
import path from 'node:path';
import crypto from 'node:crypto';
import dotenv from 'dotenv';

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
const apiKey = getEnv('N8N_API_KEY', { required: true });
const webhookBase = getEnv('WEBHOOK_BASE_URL', { required: true }).replace(/\/$/, '');
const leadgenAAuth = getEnv('LEADGEN_A_AUTH');
const leadgenBAuth = getEnv('LEADGEN_B_AUTH');

const apiBase = `${host}/rest`;

async function apiRequest(pathname, { method = 'GET', body } = {}) {
  const response = await fetch(`${apiBase}${pathname}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      'X-N8N-API-KEY': apiKey,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`n8n ${method} ${pathname} failed: ${response.status} ${response.statusText} ${text}`);
  }
  if (response.status === 204) {
    return null;
  }
  return response.json();
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
            value1: `={{(($json["actions"]?.${key}) || []).length > 0}}`,
            value2: true,
          },
        ],
      },
    },
  };
}

function buildHttpNode({ name, pathSuffix, bodyKey, payloadKey, authValue, position }) {
  const headers = [
    { name: 'Content-Type', value: 'application/json' },
  ];
  if (authValue) {
    headers.push({ name: 'Authorization', value: authValue });
  }
  return {
    id: crypto.randomUUID(),
    name,
    type: 'n8n-nodes-base.httpRequest',
    typeVersion: 4,
    position,
    parameters: {
      url: `${webhookBase}${pathSuffix}`,
      method: 'POST',
      jsonParameters: true,
      bodyParametersJson: `={{({ "${payloadKey}": $json["actions"]?.${bodyKey} || [] })}}`,
      headerParameters: headers,
      options: {
        retryOnFail: true,
        maxRetries: 3,
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

    const hasToANode = buildIfNode('has_to_a', 'to_a', [baseX + 300, baseY - 150]);
    const hasToBNode = buildIfNode('has_to_b', 'to_b', [baseX + 300, baseY + 150]);

    const httpANode = buildHttpNode({
      name: 'leadgen_a_http',
      pathSuffix: '/webhook/bfl/leadgen/query-a',
      bodyKey: 'to_a',
      payloadKey: 'new_urls',
      authValue: leadgenAAuth,
      position: [baseX + 600, baseY - 150],
    });

    const httpBNode = buildHttpNode({
      name: 'leadgen_b_http',
      pathSuffix: '/webhook/bfl/leadgen/intake-b',
      bodyKey: 'to_b',
      payloadKey: 'candidates',
      authValue: leadgenBAuth,
      position: [baseX + 600, baseY + 150],
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
