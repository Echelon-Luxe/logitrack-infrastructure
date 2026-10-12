#!/usr/bin/env node
// Demo data, created through the gateway exactly as the UI would - so Kafka,
// tracking, notifications and earnings all fill in for real, and every step
// doubles as an end-to-end check of the permission rules.
//
//   node seed.mjs            (needs `./dev.sh up` and `./dev.sh seed-users`)
//
// Re-running is safe: it skips shipment creation once the demo set exists.

const API = process.env.API ?? 'http://localhost:8080/api';
const PASSWORD = 'LogiTrack-demo-2026';

const PLACES = {
  ikeja: { name: 'Ikeja City Mall, Obafemi Awolowo Way, Ikeja', lat: 6.6142, lng: 3.3581 },
  lekki: { name: 'Admiralty Way, Lekki Phase 1', lat: 6.4474, lng: 3.4723 },
  vi: { name: 'Adeola Odeku St, Victoria Island', lat: 6.4305, lng: 3.4216 },
  yaba: { name: 'Herbert Macaulay Way, Yaba', lat: 6.5095, lng: 3.3711 },
  surulere: { name: 'Adeniran Ogunsanya St, Surulere', lat: 6.4926, lng: 3.3553 },
  ajah: { name: 'Lekki-Epe Expressway, Ajah', lat: 6.4682, lng: 3.5852 },
  maryland: { name: 'Maryland Mall, Ikorodu Rd, Maryland', lat: 6.5714, lng: 3.3672 },
  apapa: { name: 'Wharf Rd, Apapa', lat: 6.4489, lng: 3.3594 },
  festac: { name: '2nd Avenue, Festac Town', lat: 6.4664, lng: 3.2834 },
  ikoyi: { name: 'Awolowo Rd, Ikoyi', lat: 6.4479, lng: 3.4344 },
  gbagada: { name: 'Diya St, Gbagada', lat: 6.548, lng: 3.3878 },
  oshodi: { name: 'Agege Motor Rd, Oshodi', lat: 6.553, lng: 3.3434 },
};

const DRIVERS = [
  { email: 'driver1@logitrack.local', vehicleType: 'Van', plateNumber: 'LND-421-KJ', phone: '+234 802 111 0011' },
  { email: 'driver2@logitrack.local', vehicleType: 'Motorbike', plateNumber: 'EKY-118-AB', phone: '+234 802 111 0012' },
  { email: 'driver3@logitrack.local', vehicleType: 'Truck', plateNumber: 'APP-903-XY', phone: '+234 802 111 0013' },
];

// [customer, from, to, outcome]. Outcomes run in order, one job per driver at
// a time, because a driver on a job is (correctly) not assignable.
const PLAN = [
  ['customer1', 'ikeja', 'lekki', 'DELIVERED'],
  ['customer2', 'yaba', 'vi', 'DELIVERED'],
  ['customer3', 'surulere', 'ajah', 'DELIVERED'],
  ['customer1', 'maryland', 'ikoyi', 'DELIVERED'],
  ['customer2', 'apapa', 'festac', 'CANCELLED'],
  ['customer1', 'gbagada', 'vi', 'IN_TRANSIT'],
  ['customer2', 'oshodi', 'lekki', 'OUT_FOR_DELIVERY'],
  ['customer3', 'festac', 'yaba', 'PICKED_UP'],
  ['customer3', 'ikoyi', 'ikeja', 'CREATED'],
  ['customer1', 'lekki', 'surulere', 'CREATED'],
  ['customer2', 'vi', 'maryland', 'CREATED'],
];

const FORWARD = ['PICKED_UP', 'IN_TRANSIT', 'OUT_FOR_DELIVERY', 'DELIVERED'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log('  ', ...a);

async function call(token, method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : undefined;
  return { status: res.status, body: json };
}

async function must(token, method, path, body, expect = [200, 201, 204]) {
  const r = await call(token, method, path, body);
  if (!expect.includes(r.status)) {
    throw new Error(`${method} ${path} -> ${r.status} ${JSON.stringify(r.body)}`);
  }
  return r.body;
}

async function login(who) {
  const email = who.includes('@') ? who : `${who}@logitrack.local`;
  const r = await must(null, 'POST', '/auth/login', { email, password: PASSWORD });
  return { token: r.tokens.accessToken, user: r.user };
}

async function until(what, fn, timeoutMs = 20_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await fn()) return;
    await sleep(400);
  }
  throw new Error(`timed out waiting for ${what}`);
}

const lerp = (a, b, t) => ({ lat: a.lat + (b.lat - a.lat) * t, lng: a.lng + (b.lng - a.lng) * t });

// A believable wiggle so the trail is not a ruler-straight line.
const jitter = (p, i) => ({ lat: p.lat + Math.sin(i * 1.7) * 0.0012, lng: p.lng + Math.cos(i * 1.3) * 0.0012 });

async function main() {
  console.log(`Seeding through ${API}`);

  // 1. Drivers onboard themselves; dispatch approves; drivers go online.
  const dispatch = await login('dispatch');
  const drivers = [];
  for (const d of DRIVERS) {
    const s = await login(d.email);
    let me = await call(s.token, 'GET', '/drivers/me');
    if (me.status === 404) {
      me = { body: await must(s.token, 'POST', '/drivers', { vehicleType: d.vehicleType, plateNumber: d.plateNumber, phone: d.phone }) };
      log(`driver profile created for ${s.user.name}`);
    }
    // A pending driver cannot go online - check the rule holds.
    if (!me.body.approvedAt) {
      const early = await call(s.token, 'POST', `/drivers/${me.body.id}/availability`, { availability: 'ONLINE' });
      if (early.status !== 403) throw new Error(`unapproved driver went online (${early.status})`);
      await must(dispatch.token, 'POST', `/drivers/${me.body.id}/approve`, { approved: true });
      log(`dispatch approved ${s.user.name}`);
    }
    if (me.body.availability !== 'ONLINE') {
      await must(s.token, 'POST', `/drivers/${me.body.id}/availability`, { availability: 'ONLINE' });
    }
    drivers.push({ ...s, driverId: me.body.id });
  }

  const existing = await must(dispatch.token, 'GET', '/shipments?limit=200');
  if (existing.length >= PLAN.length) {
    console.log(`✓ ${existing.length} shipments already exist; skipping creation`);
    return;
  }

  // 2. Customers order; some pay up front (mock provider).
  const customers = {};
  for (const c of ['customer1', 'customer2', 'customer3']) customers[c] = await login(c);

  const created = [];
  for (const [cust, from, to, outcome] of PLAN) {
    const c = customers[cust];
    const a = PLACES[from];
    const b = PLACES[to];
    const s = await must(c.token, 'POST', '/shipments', {
      customerPhone: c.user.phone ?? undefined,
      origin: a.name, destination: b.name,
      originLat: a.lat, originLng: a.lng, destLat: b.lat, destLng: b.lng,
    });
    if (outcome !== 'CANCELLED') {
      const init = await call(c.token, 'POST', '/payments/initialize', { shipmentId: s.id });
      if (init.status === 201) await must(c.token, 'POST', `/payments/${init.body.reference}/mock-complete`, { succeeded: true });
    }
    created.push({ s, c, a, b, outcome });
    log(`${c.user.name}: ${s.reference} ${from} → ${to} ₦${(s.priceKobo / 100).toLocaleString()}`);
  }

  // A customer must not see someone else's shipment; prove it.
  const peek = await call(customers.customer3.token, 'GET', `/shipments/${created[0].s.id}`);
  if (peek.status !== 404) throw new Error(`customer read another customer's shipment (${peek.status})`);

  // 3. Dispatch works the queue.
  let next = 0;
  const freeDriver = async () => {
    for (let tries = 0; tries < 60; tries++) {
      const d = drivers[next % drivers.length];
      next++;
      const view = await must(dispatch.token, 'GET', `/drivers/${d.driverId}`);
      if (view.status === 'AVAILABLE') return d;
      await sleep(300);
    }
    throw new Error('no driver became available');
  };

  for (const job of created) {
    if (job.outcome === 'CREATED') continue;
    if (job.outcome === 'CANCELLED') {
      await must(job.c.token, 'POST', `/shipments/${job.s.id}/status`, { status: 'CANCELLED' });
      log(`${job.s.reference} cancelled by customer`);
      continue;
    }

    const d = await freeDriver();
    await must(dispatch.token, 'POST', `/shipments/${job.s.id}/assign`, { driverId: d.driverId });
    // Driver-service learns of the assignment from Kafka.
    await until(`${d.user.name} on job`, async () =>
      (await must(dispatch.token, 'GET', `/drivers/${d.driverId}`)).status === 'ON_JOB');

    const target = FORWARD.indexOf(job.outcome);
    for (let i = 0; i <= target; i++) {
      await must(d.token, 'POST', `/shipments/${job.s.id}/status`, { status: FORWARD[i] });
    }

    if (job.outcome !== 'DELIVERED') {
      // Tracking must have caught up before it accepts the driver's pings.
      await until(`tracking for ${job.s.reference}`, async () => {
        const t = await call(d.token, 'GET', `/tracking/${job.s.id}/latest`);
        return t.status === 200 && t.body.status === job.outcome;
      });
      const progress = { PICKED_UP: 0.12, IN_TRANSIT: 0.48, OUT_FOR_DELIVERY: 0.84 }[job.outcome];
      const steps = 10;
      for (let i = 0; i <= steps; i++) {
        const p = jitter(lerp(job.a, job.b, (progress * i) / steps), i);
        await must(d.token, 'POST', `/tracking/${job.s.id}/location`, { ...p, speedKph: 25 + (i % 4) * 6 });
      }
    } else {
      await until(`${d.user.name} released`, async () =>
        (await must(dispatch.token, 'GET', `/drivers/${d.driverId}`)).status === 'AVAILABLE');
    }
    log(`${job.s.reference} → ${job.outcome} (${d.user.name})`);
  }

  // Support is read-only: it can see everything but change nothing.
  const support = await login('support');
  const denied = await call(support.token, 'POST', `/shipments/${created[8].s.id}/status`, { status: 'CANCELLED' });
  if (denied.status !== 403) throw new Error(`support changed a shipment (${denied.status})`);

  console.log(`\n✓ seeded ${created.length} shipments. Sign in at http://localhost:3000 with any demo account (password ${PASSWORD}).`);
}

main().catch((err) => {
  console.error(`\n✗ ${err.message}`);
  process.exit(1);
});
