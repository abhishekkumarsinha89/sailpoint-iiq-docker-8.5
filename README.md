# SailPoint IdentityIQ — Docker Compose Setup

> Deploy a full SailPoint IIQ 8.5 stack on Windows using Docker Desktop.
> Tested and working with IIQ 8.5, MySQL 8.0, Tomcat 9 (JDK 11).

---

## Table of Contents

1. [Stack Overview](#1-stack-overview)
2. [Project Structure](#2-project-structure)
3. [Prerequisites](#3-prerequisites)
4. [Environment Configuration](#4-environment-configuration)
5. [First-Time Installation](#5-first-time-installation)
6. [Accessing the Applications](#6-accessing-the-applications)
7. [Day-to-Day Maintenance](#7-day-to-day-maintenance)
8. [Upgrading IIQ Version](#8-upgrading-iiq-version)
9. [Troubleshooting](#9-troubleshooting)
10. [How It Works — Architecture Notes](#10-how-it-works--architecture-notes)
11. [Security Notes](#11-security-notes)
12. [References](#12-references)

---

## 1. Stack Overview

All configuration is driven from a single `.env` file — nothing is hardcoded.

| Container         | Image                                      | Host Port            | Purpose                        |
|-------------------|--------------------------------------------|----------------------|--------------------------------|
| `iiq-mysql`       | `mysql:${MYSQL_VERSION}`                   | `${MYSQL_PORT}`      | IIQ + Access History databases |
| `iiq-tomcat`      | `tomcat:${TOMCAT_VERSION}` (custom build)  | `${TOMCAT_PORT}`     | Tomcat + IIQ application       |
| `iiq-phpmyadmin`  | `phpmyadmin:${PHPMYADMIN_VERSION}`         | `${PHPMYADMIN_PORT}` | Web-based DB admin UI          |

All containers communicate over a private Docker bridge network (`iiq-network`).
All data is persisted in named Docker volumes so it survives container restarts.

### Databases created automatically on first boot

| Database           | Purpose                                       |
|--------------------|-----------------------------------------------|
| `identityiq`       | Main IIQ schema (identities, roles, tasks…)   |
| `identityiqPlugin` | IIQ plugin storage                            |
| `identityiqah`     | Access History — introduced in IIQ 8.5        |

---

## 2. Project Structure

```
sailpoint-iiq-docker/
│
├── docker-compose.yml              ← Full stack definition (all values from .env)
├── .env                            ← Your config — created from .env.example
├── .env.example                    ← Template — copy to .env before first run
│
├── iiq-build/                      ← Custom Tomcat + IIQ Docker image
│   ├── Dockerfile                  ← Builds from official Tomcat, extracts IIQ WAR
│   ├── entrypoint.sh               ← Patches iiq.properties, creates schemas, starts Tomcat
│   ├── conf/
│   │   └── server.xml              ← Tomcat config (URIEncoding=UTF-8, tuned connectors)
│   ├── lib/                        ← Empty — JDBC driver is bundled inside identityiq.war
│   └── src/
│       └── identityiq-8.5.zip      ← YOU MUST PLACE THIS HERE (download from Compass)
│
└── db/
    └── init/                       ← Optional extra MySQL init .sql scripts
```

---

## 3. Prerequisites

### Docker Desktop for Windows
- Download: https://www.docker.com/products/docker-desktop/
- During installation, enable the **WSL 2** backend
- After install, open **Settings → Resources** and allocate:
  - Memory: **6 GB minimum** (IIQ is memory-hungry)
  - CPUs: **2 minimum**
- Verify in PowerShell:
```powershell
docker --version
docker compose version
```

### SailPoint IIQ Binary (proprietary — required)
- Requires a SailPoint **customer or partner** Compass account
- Log in at: https://compass.sailpoint.com
- Navigate: **Downloads → IdentityIQ → 8.5**
- Download: `identityiq-8.5.zip`
- Place at: `.\iiq-build\src\identityiq-8.5.zip`

> The MySQL JDBC connector ships inside `identityiq.war` — no separate download needed.

### Port availability
The following host ports must be free. Change any of them in `.env` if already in use.

| Default | Service       | `.env` variable      |
|---------|---------------|----------------------|
| `8888`  | IIQ / Tomcat  | `TOMCAT_PORT`        |
| `8800`  | Tomcat debug  | `TOMCAT_DEBUG_PORT`  |
| `3386`  | MySQL         | `MYSQL_PORT`         |
| `8870`  | phpMyAdmin    | `PHPMYADMIN_PORT`    |

To check if a port is already taken on Windows:
```powershell
netstat -ano | findstr :3306
```

> **Common gotcha:** If you have a local MySQL service installed on Windows it will
> hold port 3306. Set `MYSQL_PORT=3386` (or any free port) in `.env` to avoid the
> conflict. Container-to-container traffic always uses port 3306 internally regardless.

---

## 4. Environment Configuration

Copy the example and edit it:
```powershell
copy .env.example .env
notepad .env
```

Full reference for all variables:

```env
# -----------------------------------------------------------------------
# IIQ Version — MUST match the zip filename exactly
# e.g. identityiq-8.5.zip → IIQ_VERSION=8.5
# -----------------------------------------------------------------------
IIQ_VERSION=8.5

# -----------------------------------------------------------------------
# Tomcat — recommended: 9.x with JDK 11 for IIQ 8.x
# -----------------------------------------------------------------------
TOMCAT_VERSION=9.0-jdk11-openjdk-slim
TOMCAT_PORT=8888          # Host port → http://localhost:8888/identityiq
TOMCAT_DEBUG_PORT=8800    # JPDA remote debug port

# -----------------------------------------------------------------------
# MySQL
# MYSQL_PORT is the HOST-side port only.
# Containers always talk to each other on 3306 internally.
# -----------------------------------------------------------------------
MYSQL_VERSION=8.0
MYSQL_PORT=3386
MYSQL_DATABASE=identityiq
MYSQL_USER=identityiq
MYSQL_PASSWORD=identityiq
MYSQL_ROOT_PASSWORD=rootpassword

# -----------------------------------------------------------------------
# phpMyAdmin
# -----------------------------------------------------------------------
PHPMYADMIN_VERSION=latest
PHPMYADMIN_PORT=8870
```

---

## 5. First-Time Installation

### Step 1 — Place the IIQ binary

```powershell
copy C:\Downloads\identityiq-8.5.zip .\iiq-build\src\
```

Confirm it is there:
```powershell
dir .\iiq-build\src\
# Must show: identityiq-8.5.zip
```

### Step 2 — Build the Docker image

```powershell
docker compose build
```

What this does:
- Pulls the base `tomcat:9.0-jdk11-openjdk-slim` image from Docker Hub
- Installs `mysql-client`, `unzip`, and `curl` inside the image
- Extracts `identityiq.war` from your zip into Tomcat's webapps folder
- Extracts the database DDL scripts for use at runtime by `entrypoint.sh`
- Copies `entrypoint.sh` which handles all first-boot bootstrapping

Expected duration: **2–5 minutes** on first build (depends on internet speed).

To rebuild from scratch with no cache:
```powershell
docker compose build --no-cache
```

### Step 3 — Start the stack

```powershell
docker compose up -d
```

### Step 4 — Follow startup logs

```powershell
docker compose logs -f iiq
```

On first boot, `entrypoint.sh` runs through these stages automatically:

```
==========================================
 Patching iiq.properties with MySQL config...
==========================================
  Main DB:           jdbc:mysql://iiq-mysql:3306/identityiq      ✅
  Access History DB: jdbc:mysql://iiq-mysql:3306/identityiqah    ✅
  Plugin DB:         jdbc:mysql://iiq-mysql:3306/identityiqPlugin ✅
==========================================
 Waiting for MySQL at iiq-mysql:3306...
==========================================
  [attempt 1] MySQL not ready yet - retrying in 5s...
  MySQL is ready!
==========================================
 Initializing IIQ database schema...
==========================================
  Using schema script: /opt/iiq/database/create_identityiq_tables-8.5.mysql
  Schema created successfully.
  Access History schema created successfully.
  Running plugin schema script: ...
==========================================
 Importing IIQ default configuration (init.xml)...
 This may take several minutes...
==========================================
  IIQ initialization complete.
==========================================
 Starting Apache Tomcat...
 IIQ will be available at:
   http://localhost:8888/identityiq
==========================================
```

> First boot takes **5–10 minutes** total. The `init.xml` import is the slow step.
> **Do NOT restart the container while initializing** — this interrupts the schema
> import and corrupts the database, requiring a full `docker compose down -v` reset.

### Step 5 — Verify all containers are healthy

```powershell
docker ps
```

Expected output:
```
CONTAINER ID   NAME             STATUS
xxxxxxxxxxxx   iiq-tomcat       Up X minutes (healthy)
xxxxxxxxxxxx   iiq-phpmyadmin   Up X minutes
xxxxxxxxxxxx   iiq-mysql        Up X minutes (healthy)
```

---

## 6. Accessing the Applications

Once you see `Starting Apache Tomcat...` in the logs, wait an additional
**60–90 seconds** for IIQ to finish loading servlets before opening the browser.

| Application        | URL                                  | Credentials              |
|--------------------|--------------------------------------|--------------------------|
| **IdentityIQ**     | http://localhost:8888/identityiq     | `spadmin` / `admin`      |
| **phpMyAdmin**     | http://localhost:8870                | `root` / `rootpassword`  |
| **Tomcat Manager** | http://localhost:8888/manager/html   | Tomcat defaults          |
| **MySQL (direct)** | `localhost:3386`                     | `identityiq` / `identityiq` |

> Ports above reflect the defaults. Substitute with your actual `.env` values if changed.

---

## 7. Day-to-Day Maintenance

### Starting and stopping

```powershell
# Start all containers (resumes from where you left off, data intact)
docker compose start

# Stop all containers gracefully (data is fully preserved)
docker compose stop

# Stop AND remove containers (named volumes and data still preserved)
docker compose down

# ⚠️  FULL RESET — destroys ALL containers AND ALL DATA including the database
docker compose down -v
```

### Viewing logs

```powershell
# Live logs from all containers
docker compose logs -f

# Live logs from IIQ/Tomcat only
docker compose logs -f iiq

# Live logs from MySQL only
docker compose logs -f db

# Last 100 lines from IIQ (useful after an overnight restart)
docker logs iiq-tomcat --tail 100

# Last 100 lines from MySQL
docker logs iiq-mysql --tail 100
```

### Opening a shell inside a container

```powershell
# Bash shell inside the IIQ/Tomcat container
docker exec -it iiq-tomcat bash

# MySQL shell as the identityiq application user
docker exec -it iiq-mysql mysql -u identityiq -pidentityiq identityiq

# MySQL shell as root (full access to all databases)
docker exec -it iiq-mysql mysql -u root -prootpassword

# Check Access History database tables
docker exec -it iiq-mysql mysql -u root -prootpassword \
  -e "SHOW TABLES IN identityiqah;"
```

### Checking container health

```powershell
# Show all running containers with status
docker ps

# Detailed health check status for IIQ
docker inspect iiq-tomcat --format "{{json .State.Health}}"

# Detailed health check status for MySQL
docker inspect iiq-mysql --format "{{json .State.Health}}"
```

### Checking named volumes

```powershell
# List all named volumes for this stack
docker volume ls | findstr iiq

# Show where a volume is physically stored
docker volume inspect iiq-mysql-data
docker volume inspect iiq-webapps
docker volume inspect iiq-logs
```

### Restarting a single service without losing data

```powershell
# Restart just the IIQ/Tomcat container (e.g. after a config tweak)
docker compose restart iiq

# Restart just MySQL
docker compose restart db

# Restart phpMyAdmin
docker compose restart phpmyadmin
```

### Verifying iiq.properties was patched correctly

```powershell
docker exec -it iiq-tomcat grep -E "dataSource.url|pluginsDataSource.url" \
  /usr/local/tomcat/webapps/identityiq/WEB-INF/classes/iiq.properties
```

Expected output (all pointing to `iiq-mysql`, not `localhost`):
```
dataSource.url=jdbc:mysql://iiq-mysql:3306/identityiq?useSSL=false...
pluginsDataSource.url=jdbc:mysql://iiq-mysql:3306/identityiqPlugin?useSSL=false...
```

### Verifying all three databases exist

```powershell
docker exec -it iiq-mysql mysql -u root -prootpassword \
  -e "SHOW DATABASES;" 2>/dev/null
```

Expected output includes:
```
identityiq
identityiqPlugin
identityiqah
```

---

## 8. Upgrading IIQ Version

> ⚠️ This destroys all existing IIQ data. Export anything you need first.

```powershell
# 1. Download the new zip from https://compass.sailpoint.com
#    and place it in .\iiq-build\src\
copy C:\Downloads\identityiq-8.6.zip .\iiq-build\src\

# 2. Update IIQ_VERSION in .env to match the new zip filename exactly
notepad .env
# Change: IIQ_VERSION=8.6

# 3. Full teardown including all volumes (destroys all data)
docker compose down -v

# 4. Rebuild the image from scratch with no cache
docker compose build --no-cache

# 5. Start fresh — first-boot initialization runs again automatically
docker compose up -d
docker compose logs -f iiq
```

---

## 9. Troubleshooting

### ERR_EMPTY_RESPONSE — page won't load at all

Tomcat is running but IIQ crashed during startup and is not serving anything.

```powershell
docker logs iiq-tomcat --tail 100
```

Look for `SEVERE` or `ERROR` lines to identify the specific failure.

---

### Port already in use

```
Error response from daemon: ports are not available: exposing port TCP 0.0.0.0:3306
```

A local service (usually Windows MySQL) is holding the port.

```powershell
# Find the process holding the port
netstat -ano | findstr :3306
```

Fix: change the conflicting port in `.env` (e.g. `MYSQL_PORT=3386`), then:
```powershell
docker compose down
docker compose up -d
```

---

### "Unable to connect to identityiqah" — Access History DB error (IIQ 8.5)

```
Unable to connect to: jdbc:mysql://localhost/identityiqah
```

IIQ 8.5 added a dedicated Access History database. The stock `iiq.properties`
hardcodes its JDBC URL to `localhost`, which fails in Docker.

The `entrypoint.sh` patches this at runtime. If you see this error, an old
cached image is being used. Force a full rebuild:

```powershell
docker compose down -v
docker compose build --no-cache
docker compose up -d
```

---

### "Invalid key 'datasource': expected 'beanName.property'"

A custom `iiq.properties` was copied into the container overwriting IIQ's own file,
breaking Spring's `PropertyOverrideConfigurer`. This project intentionally does NOT
copy a custom `iiq.properties`. The `entrypoint.sh` patches the original file at
runtime using `sed` instead.

Check the Dockerfile has no `COPY conf/iiq.properties` line. If it does, remove it
and rebuild.

---

### "The main resource set [.../manager] is not valid"

The Tomcat `manager` webapp was deleted from the image but a `manager.xml` descriptor
still referenced it. This project leaves all default Tomcat webapps intact.

Check the Dockerfile has no line deleting `webapps/manager`. If it does, remove it
and rebuild.

---

### Schema not created / spt_identity table missing

```powershell
# Check if main IIQ tables exist
docker exec -it iiq-mysql mysql -u root -prootpassword \
  -e "SHOW TABLES IN identityiq;" 2>/dev/null
```

If empty, the schema script didn't run. Check the logs:
```powershell
docker logs iiq-tomcat | findstr -i "schema\|error\|ERROR"
```

Full reset:
```powershell
docker compose down -v
docker compose up -d
```

---

### IIQ loads but shows 500 errors for the first few minutes

Normal — Tomcat needs 60–90 seconds after the startup message appears to finish
loading all IIQ servlets and caches. Wait and refresh.

---

### Out of memory / Java heap errors

```powershell
docker logs iiq-tomcat | findstr -i "OutOfMemory\|heap"
```

Fix: in Docker Desktop go to **Settings → Resources → Memory** and increase to
**8 GB**, then update `JAVA_OPTS` in `docker-compose.yml`:

```yaml
JAVA_OPTS: >-
  -Xms1g
  -Xmx4g
  -Dfile.encoding=UTF-8
  -Djava.awt.headless=true
```

Then restart:
```powershell
docker compose restart iiq
```

---

### Container exits immediately after starting

```powershell
docker ps -a
docker logs iiq-tomcat
```

Most common cause: `identityiq-8.5.zip` is missing from `.\iiq-build\src\` or
the filename doesn't exactly match `IIQ_VERSION` in `.env`.

```powershell
dir .\iiq-build\src\
# Must show: identityiq-8.5.zip
```

If the file is there but the name differs, either rename the file or update
`IIQ_VERSION` in `.env`, then rebuild:
```powershell
docker compose build --no-cache
docker compose up -d
```

---

## 10. How It Works — Architecture Notes

### Why iiq.properties is patched at runtime, not replaced at build time

IIQ's Spring context uses `PropertyOverrideConfigurer` which expects keys in
`beanName.property` format (e.g. `dataSource.url`). A bare key like
`datasource=identityiqDataSource` causes Spring to throw:

```
Invalid key 'datasource': expected 'beanName.property'
```

Rather than maintaining a full replacement `iiq.properties` file, `entrypoint.sh`
uses `sed` to surgically patch only the DB connection lines in the original file
that ships with IIQ, leaving all Spring bean definitions intact.

---

### Why IIQ 8.5 needs three databases

IIQ 8.5 introduced a dedicated **Access History** schema (`identityiqah`) to store
historical identity snapshots separately from the main schema. The stock
`iiq.properties` hardcodes its JDBC URL to `localhost`, which fails inside Docker
where MySQL is only reachable via the service hostname `iiq-mysql`. `entrypoint.sh`
patches this:

```bash
sed -i "s|jdbc:mysql://localhost/identityiqah|jdbc:mysql://iiq-mysql:3306/identityiqah|g" iiq.properties
```

---

### Why MYSQL_PORT in .env doesn't affect container-to-container traffic

`MYSQL_PORT` in `.env` controls the **host machine port binding** only
(e.g. `3386:3306` — host:container). Inside the Docker bridge network, all
containers always reach MySQL on `iiq-mysql:3306` regardless of the host mapping.
This is why all JDBC URLs in the entrypoint use `3306` even when your `.env` maps
MySQL to a different host port.

---

### Container startup sequence

```
docker compose up
    │
    ├─► iiq-mysql starts
    │       └─► healthcheck: mysqladmin ping (retries every 10s)
    │               └─► HEALTHY
    │
    ├─► iiq-phpmyadmin starts  (waits for db: healthy)
    │
    └─► iiq-tomcat starts      (waits for db: healthy)
            │
            ├─► patch_iiq_properties
            │       ├─► sed: dataSource.url       → iiq-mysql:3306
            │       ├─► sed: pluginsDataSource.url → iiq-mysql:3306
            │       └─► sed: identityiqah url      → iiq-mysql:3306
            │
            ├─► wait_for_mysql (mysqladmin ping loop, 5s intervals)
            │
            ├─► init_database  (FIRST BOOT ONLY — skipped if spt_identity exists)
            │       ├─► create_identityiq_tables-8.5.mysql  (main schema)
            │       ├─► identityiqah database + grant        (Access History)
            │       ├─► plugin schema script                 (if present)
            │       └─► iiq console: import init.xml         (5–8 mins)
            │
            └─► catalina.sh run  (Tomcat starts, IIQ becomes accessible)
```

---

## 11. Security Notes

This setup is designed for **local development only**. Before exposing to any
shared or networked environment:

- Change all passwords in `.env` — `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`
- Change the IIQ default admin password (`spadmin`) immediately after first login
- Remove or firewall phpMyAdmin (remove the service from `docker-compose.yml`)
- Enable HTTPS on the Tomcat connector in `server.xml`
- Do not commit your `.env` file to version control — add it to `.gitignore`
- Restrict `JAVA_OPTS` debug port (`8800`) — it allows unauthenticated remote code execution

---

## 12. References

- [SailPoint Compass Downloads](https://compass.sailpoint.com)
- [Dockerization of IdentityIQ — SailPoint Community Wiki](https://community.sailpoint.com/t5/IdentityIQ-Wiki/Dockerization-of-IdentityIQ/ta-p/136819)
- [docker-IdentityIQ by Ghooosstt (GitHub)](https://github.com/Ghooosstt/docker-IdentityIQ)
- [IIQ-in-Docker — IdentityWorksLLC (GitLab)](https://git.identityworksllc.com/pub/sailpoint-docker)
- [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/)
- [SailPoint IIQ 8.5 Documentation](https://compass.sailpoint.com)


## See IIQ Logs 
- docker compose logs -f iiq

## See Tomcat logs
docker logs iiq-tomcat --follow
