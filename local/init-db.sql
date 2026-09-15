-- One database and one role per service.
--
-- Separate databases (not separate schemas in one database) so no service can
-- read another's tables even by accident. In staging and production these
-- become separate RDS instances; the ownership boundary is identical, only the
-- physical separation differs.

CREATE ROLE users_svc       WITH LOGIN PASSWORD 'users_svc';
CREATE ROLE shipments_svc   WITH LOGIN PASSWORD 'shipments_svc';
CREATE ROLE drivers_svc     WITH LOGIN PASSWORD 'drivers_svc';
CREATE ROLE tracking_svc    WITH LOGIN PASSWORD 'tracking_svc';
CREATE ROLE notifications_svc WITH LOGIN PASSWORD 'notifications_svc';

CREATE DATABASE usersdb         OWNER users_svc;
CREATE DATABASE shipmentsdb     OWNER shipments_svc;
CREATE DATABASE driversdb       OWNER drivers_svc;
CREATE DATABASE trackingdb      OWNER tracking_svc;
CREATE DATABASE notificationsdb OWNER notifications_svc;

-- Revoke the default PUBLIC connect grant so only the owning role can attach.
REVOKE CONNECT ON DATABASE usersdb         FROM PUBLIC;
REVOKE CONNECT ON DATABASE shipmentsdb     FROM PUBLIC;
REVOKE CONNECT ON DATABASE driversdb       FROM PUBLIC;
REVOKE CONNECT ON DATABASE trackingdb      FROM PUBLIC;
REVOKE CONNECT ON DATABASE notificationsdb FROM PUBLIC;
