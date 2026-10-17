// Hilfsskript für setup.sh: spricht die interne REST-API von n8n an
// (getestet mit der in test/docker-compose.yml festgelegten n8n-Version).
import { readdirSync, readFileSync } from 'node:fs';

const BASE = process.env.N8N_URL ?? 'http://n8n:5678';
const LOGIN = { email: process.env.TEST_LOGIN_EMAIL, password: process.env.TEST_LOGIN_PASSWORD };
const DIR = '/workflows';
// 03 (Notion) läuft offline nicht; 04, 05 und 06 werden aktiviert, damit Formulare
// und der Webhook von 06 erreichbar sind
const SKIP = /^03_/;
const ACTIVATE = /^0[456]_/;

let cookie = '';
async function api(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { 'content-type': 'application/json', cookie },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const setCookie = res.headers.get('set-cookie');
  if (setCookie) cookie = setCookie.split(';')[0];
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = text; }
  return { status: res.status, data: data?.data ?? data };
}

async function waitReady() {
  for (let i = 0; i < 120; i++) {
    try { if ((await fetch(BASE + '/healthz/readiness')).ok) return; } catch {}
    await new Promise(r => setTimeout(r, 2000));
  }
  throw new Error('n8n antwortet nicht');
}

async function login() {
  const r = await api('POST', '/rest/login', { emailOrLdapLoginId: LOGIN.email, password: LOGIN.password });
  if (r.status !== 200) {
    throw new Error(`Login mit ${LOGIN.email} fehlgeschlagen (${r.status}). Wurde n8n vorher von Hand `
      + 'registriert? Dann die Testumgebung neu anlegen: docker compose -f test/docker-compose.yml down -v, '
      + 'danach up -d --build und warten, bis "docker compose -f test/docker-compose.yml logs n8n-setup" '
      + '"importiert" zeigt. Erst dann n8n öffnen und mit dem Test-Login anmelden, nicht registrieren.');
  }
}

async function owner() {
  await waitReady();
  const r = await api('POST', '/rest/owner/setup', { ...LOGIN, firstName: 'Test', lastName: 'Buchhaltung' });
  console.log(r.status === 200 ? `Login angelegt: ${LOGIN.email}` : 'Login existiert bereits, melde mich an');
  await login();
}

async function workflows() {
  await waitReady();
  await login();
  const existing = (await api('GET', '/rest/workflows')).data;
  for (const file of readdirSync(DIR).filter(f => f.endsWith('.json') && !SKIP.test(f)).sort()) {
    const w = JSON.parse(readFileSync(`${DIR}/${file}`, 'utf8'));
    // Gleicher Workflow = gleiches Präfix "01 · ", auch wenn sich die Version im Namen geändert hat
    const prefix = w.name.split(' · ')[0] + ' · ';
    for (const old of existing.filter(x => x.name.startsWith(prefix))) {
      if (old.active) await api('POST', `/rest/workflows/${old.id}/deactivate`);
      await api('POST', `/rest/workflows/${old.id}/archive`);
      await api('DELETE', `/rest/workflows/${old.id}`);
    }
    const created = await api('POST', '/rest/workflows', {
      name: w.name, nodes: w.nodes, connections: w.connections, settings: w.settings, active: false,
    });
    if (created.status >= 300) throw new Error(`${file}: Import fehlgeschlagen (${created.status}) ${JSON.stringify(created.data).slice(0, 300)}`);
    let state = 'importiert';
    if (ACTIVATE.test(file)) {
      const a = await api('POST', `/rest/workflows/${created.data.id}/activate`, { versionId: created.data.versionId });
      if (a.status >= 300) throw new Error(`${file}: Aktivieren fehlgeschlagen (${a.status}) ${JSON.stringify(a.data).slice(0, 300)}`);
      state = 'importiert und aktiviert';
    }
    console.log(`${file}: ${state}`);
  }
}

const step = process.argv[2];
if (step === 'owner') await owner();
else if (step === 'workflows') await workflows();
else throw new Error('Aufruf: setup.mjs owner|workflows');
