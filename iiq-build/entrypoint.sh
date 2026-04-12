#!/bin/bash
# =============================================================================
# SailPoint IIQ - Container Entrypoint Script
# Waits for MySQL, initializes the IIQ schema if needed, then starts Tomcat
# =============================================================================

set -e

MYSQL_HOST="${MYSQL_HOST:-iiq-mysql}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-identityiq}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-identityiq}"
MYSQL_DATABASE="${MYSQL_DATABASE:-identityiq}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-rootpassword}"
IIQ_VERSION="${IIQ_VERSION:-8.5}"

IIQ_HOME="/usr/local/tomcat/webapps/identityiq"
IIQ_BIN="${IIQ_HOME}/WEB-INF/bin/iiq"
IIQ_PROPS="${IIQ_HOME}/WEB-INF/classes/iiq.properties"

# -------------------------------------------------------------------------
# Helper: patch_iiq_properties
# Patches the stock iiq.properties that ships inside the WAR with the
# correct MySQL connection details. We use sed so we never overwrite the
# full file (which would break Spring's bean key expectations).
# -------------------------------------------------------------------------
patch_iiq_properties() {
  echo "=========================================="
  echo " Patching iiq.properties with MySQL config..."
  echo "=========================================="

  if [ ! -f "${IIQ_PROPS}" ]; then
    echo "ERROR: ${IIQ_PROPS} not found. Was the WAR extracted correctly?"
    exit 1
  fi

  # Patch the datasource JDBC URL
  sed -i "s|^dataSource.url=.*|dataSource.url=jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}?useSSL=false\&allowPublicKeyRetrieval=true\&serverTimezone=UTC\&characterEncoding=utf8\&useUnicode=true|" "${IIQ_PROPS}"

  # Patch credentials
  sed -i "s|^dataSource.username=.*|dataSource.username=${MYSQL_USER}|" "${IIQ_PROPS}"
  sed -i "s|^dataSource.password=.*|dataSource.password=${MYSQL_PASSWORD}|" "${IIQ_PROPS}"

  # Patch the plugin datasource URL (same host, different DB)
  sed -i "s|^pluginsDataSource.url=.*|pluginsDataSource.url=jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}Plugin?useSSL=false\&allowPublicKeyRetrieval=true\&serverTimezone=UTC\&characterEncoding=utf8\&useUnicode=true|" "${IIQ_PROPS}"
  sed -i "s|^pluginsDataSource.username=.*|pluginsDataSource.username=${MYSQL_USER}|" "${IIQ_PROPS}"
  sed -i "s|^pluginsDataSource.password=.*|pluginsDataSource.password=${MYSQL_PASSWORD}|" "${IIQ_PROPS}"

  # Patch the Access History datasource (new in IIQ 8.5)
  # Stock iiq.properties hardcodes this to localhost — replace with Docker service name
  sed -i "s|jdbc:mysql://localhost/identityiqah|jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/identityiqah|g" "${IIQ_PROPS}"
  sed -i "s|^accessHistoryDataSource.username=.*|accessHistoryDataSource.username=${MYSQL_USER}|" "${IIQ_PROPS}"
  sed -i "s|^accessHistoryDataSource.password=.*|accessHistoryDataSource.password=${MYSQL_PASSWORD}|" "${IIQ_PROPS}"

  echo "  iiq.properties patched successfully."
  echo "  Main DB:          jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}"
  echo "  Access History DB: jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/identityiqah"
  echo "  Plugin DB:        jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}Plugin"
}

# -------------------------------------------------------------------------
# Helper: wait_for_mysql
# Loops until MySQL is accepting connections on the expected host/port
# -------------------------------------------------------------------------
wait_for_mysql() {
  echo "=========================================="
  echo " Waiting for MySQL at ${MYSQL_HOST}:${MYSQL_PORT}..."
  echo "=========================================="
  ATTEMPTS=0
  until mysqladmin ping -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" \
        -u root -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null; do
    ATTEMPTS=$((ATTEMPTS+1))
    echo "  [attempt ${ATTEMPTS}] MySQL not ready yet - retrying in 5s..."
    sleep 5
    if [ $ATTEMPTS -ge 60 ]; then
      echo "ERROR: MySQL did not become ready after 5 minutes. Aborting."
      exit 1
    fi
  done
  echo "  MySQL is ready!"
}

# -------------------------------------------------------------------------
# Helper: db_initialized
# Returns 0 (true) if the spt_identity table already exists
# -------------------------------------------------------------------------
db_initialized() {
  mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" \
        -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
        -e "SELECT 1 FROM ${MYSQL_DATABASE}.spt_identity LIMIT 1;" \
        2>/dev/null
}

# -------------------------------------------------------------------------
# Helper: init_database
# Runs the IIQ DDL script and imports init.xml via iiq console
# -------------------------------------------------------------------------
init_database() {
  echo "=========================================="
  echo " Initializing IIQ database schema..."
  echo "=========================================="

  # Find the MySQL DDL script from the extracted IIQ zip
  DB_SCRIPT=$(find /opt/iiq/database -name "create_identityiq_tables-${IIQ_VERSION}.mysql" 2>/dev/null | head -1)

  if [ -z "${DB_SCRIPT}" ]; then
    # Fallback: look for any mysql script
    DB_SCRIPT=$(find /opt/iiq/database -name "*.mysql" 2>/dev/null | head -1)
  fi

  if [ -z "${DB_SCRIPT}" ]; then
    echo "ERROR: Could not find IIQ MySQL schema script in /opt/iiq/database/"
    echo "       Please check your identityiq-${IIQ_VERSION}.zip was correctly placed."
    exit 1
  fi

  echo "  Using schema script: ${DB_SCRIPT}"

  # Run schema creation as root (script creates the DB and grants)
  mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" \
        -u root -p"${MYSQL_ROOT_PASSWORD}" < "${DB_SCRIPT}"

  echo "  Schema created successfully."

  # Run Access History schema (new in IIQ 8.5 — separate identityiqah database)
  AH_SCRIPT=$(find /opt/iiq/database -name "create_identityiq_tables-${IIQ_VERSION}-ah.mysql" 2>/dev/null | head -1)
  if [ -n "${AH_SCRIPT}" ]; then
    echo "  Running Access History schema script: ${AH_SCRIPT}"
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" \
          -u root -p"${MYSQL_ROOT_PASSWORD}" < "${AH_SCRIPT}"
    echo "  Access History schema created successfully."
  else
    # If no dedicated script, create the identityiqah database manually so
    # IIQ can connect to it without crashing on startup
    echo "  No Access History script found — creating identityiqah database manually..."
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" \
          -u root -p"${MYSQL_ROOT_PASSWORD}" \
          -e "CREATE DATABASE IF NOT EXISTS identityiqah CHARACTER SET utf8mb4; \
              GRANT ALL PRIVILEGES ON identityiqah.* TO '${MYSQL_USER}'@'%'; \
              FLUSH PRIVILEGES;"
    echo "  identityiqah database created."
  fi

  # Also run plugin schema if present
  PLUGIN_SCRIPT=$(find /opt/iiq/database -name "create_identityiq_tables-${IIQ_VERSION}-plugin.mysql" 2>/dev/null | head -1)
  if [ -n "${PLUGIN_SCRIPT}" ]; then
    echo "  Running plugin schema script: ${PLUGIN_SCRIPT}"
    mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" \
          -u root -p"${MYSQL_ROOT_PASSWORD}" < "${PLUGIN_SCRIPT}"
  fi

  # -----------------------------------------------------------------------
  # Import IIQ default configuration via iiq console
  # -----------------------------------------------------------------------
  echo "=========================================="
  echo " Importing IIQ default configuration (init.xml)..."
  echo " This may take several minutes..."
  echo "=========================================="

  cd "${IIQ_HOME}/WEB-INF"
  echo "import init.xml" | "${IIQ_BIN}" console -e

  echo "  IIQ initialization complete."
}

# =========================================================================
# MAIN
# =========================================================================

patch_iiq_properties

wait_for_mysql

if db_initialized; then
  echo "=========================================="
  echo " IIQ database already initialized. Skipping schema setup."
  echo "=========================================="
else
  init_database
fi

echo "=========================================="
echo " Starting Apache Tomcat..."
echo " IIQ will be available at:"
echo "   http://localhost:${TOMCAT_PORT}/identityiq"
echo "   (using IIQ version ${IIQ_VERSION})"
echo " Default login: spadmin / admin"
echo "=========================================="

# Start Tomcat in foreground (required for Docker logging)
exec catalina.sh run
