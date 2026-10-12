# Roles and permissions

LogiTrack has five roles. Each user has exactly one.

| Role | For |
|---|---|
| **ADMIN** | Everything, including users, roles and the audit log |
| **DISPATCHER** | Runs operations: approves drivers, assigns jobs, manages every shipment |
| **SUPPORT** | Read-only across shipments, customers, drivers and payments |
| **DRIVER** | Their own assigned jobs, live location, their earnings |
| **CUSTOMER** | Their own shipments: book, pay, cancel before pickup, track |

Self sign-up can only create CUSTOMER or DRIVER accounts. Staff accounts are
created by an ADMIN (`POST /api/users`). New drivers cannot go online until
dispatch approves them.

## Matrix

| Capability | ADMIN | DISPATCHER | SUPPORT | DRIVER | CUSTOMER |
|---|:-:|:-:|:-:|:-:|:-:|
| Create shipment | any customer | any customer | – | – | self |
| Read shipments, tracking | all | all | all | assigned | own |
| Assign driver | ✓ | ✓ | – | – | – |
| Change status | any legal move | any legal move | – | forward on own job, never cancel | cancel own while `CREATED` |
| Report live location | – | – | – | own job, while moving | – |
| Read drivers | all | all | all | self | – |
| Driver availability | ✓ | ✓ | – | self, once approved | – |
| Approve / revoke drivers | ✓ | ✓ | – | – | – |
| List / read users | ✓ | ✓ | ✓ | – | – |
| Create users, change roles, disable, revoke sessions | ✓ | – | – | – | – |
| Audit log, dead-letter queues | ✓ | – | – | – | – |
| Start a payment | – | – | – | – | own shipment; amount set server-side |
| Read payments / earnings | all | – | all | own earnings | own payments |
| Notifications | own | own | any | own | own |

Reads outside your scope return **404**, not 403, so ids cannot be probed.

## Where it is enforced

1. **Gateway** (`logitrack-api-gateway/src/domain/routes-table.ts`): coarse,
   method-aware gate per path prefix. It verifies the JWT, **strips any
   client-supplied `x-user-*` / `x-internal-token` headers on every route**, and
   forwards `x-user-id`, `x-user-role`, `x-user-email`, `x-user-name` plus the
   shared `x-internal-token`.
2. **Each service** (`src/authz.ts`, identical in every repo): `identity(req)`
   rejects requests without the internal token (when `INTERNAL_TOKEN` is set) or
   without a valid identity; route handlers apply ownership and the matrix above.
   Rules live next to the data: `shipment-service/src/domain/access.ts`,
   `tracking-service/src/domain/locations.ts`, the route files elsewhere.
3. **Frontend** (`logitrack-frontend/src/lib/rbac.ts`): mirrors the matrix to
   decide what to *show*. It is never the enforcement point.

When a rule changes, update all three and this file.

## Sessions and changes

- Access tokens last 15 minutes; refresh tokens rotate and are revoked as a
  family on reuse.
- Changing a user's role, disabling them, or changing a password revokes all of
  their refresh tokens, so the change takes effect within one access-token
  lifetime.
- Every sign-in (successful or failed), registration, account creation, role
  change, enable/disable, session revocation and profile change is written to
  the append-only `AuditLog` in user-service (`GET /api/audit`, ADMIN only).

## Known follow-ups

- Live location fan-out is in-process; more than one tracking-service replica
  needs Redis pub/sub behind `src/domain/live.ts`.
- `INTERNAL_TOKEN` is a shared secret. mTLS or a signed per-request token from
  the gateway would be stronger, and a Kubernetes `NetworkPolicy` should limit
  backends to gateway traffic.
- Tokens are kept in `localStorage`; moving the refresh token to an httpOnly
  cookie would reduce XSS exposure.
